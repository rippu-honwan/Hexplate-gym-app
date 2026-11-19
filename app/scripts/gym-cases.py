"""Cases for Gyms (lib/gym-inventory.js syncGymInventory and switchGym): every branch."""
import copy, json, os

NOW = 1780000000000
plates_kg = {"kg": {"20": 2, "10": 2, "_ts": 100}}
plates_lb = {"lb": {"45": 4, "_ts": 300}}
bells = {"kg": {"weights": [10, 12.5, 15], "_ts": 200}}
home = {"id": "home", "name": "Home", "equipment": ["dumbbell"], "accV": 2}
big = {"id": "big", "name": "Big gym", "equipment": ["barbell", "dumbbell", "cable"], "accV": 2,
       "plates": {"kg": {"25": 4, "20": 4, "_ts": 50}}, "dumbbells": {}, "barDefaults": {"barbell": 15}, "stackWeights": {}}
noname = {"id": "x", "name": " ", "equipment": []}
base = {"unit": "kg", "plates": plates_kg, "dumbbells": bells}

def S(**kw):
    s = copy.deepcopy(base); s.update(copy.deepcopy(kw)); return s

def withinv(p, **kw):
    p = copy.deepcopy(p); p.update({"plates": {}, "dumbbells": {}, "barDefaults": {}, "stackWeights": {}}); p.update(kw); return p

cases = [
    ("no gyms", "sync", S(), None, None),
    ("no gyms, running session", "sync", S(active={"start": 1}), None, None),
    ("migration copies the lists", "sync", S(equipProfiles=[home, big], activeEquipId="home"), None, None),
    ("migration uses the lists before this change", "sync", S(equipProfiles=[home], activeEquipId="home", plates=plates_lb),
     S(equipProfiles=[home], activeEquipId="home"), None),
    ("edit goes to the active gym", "sync",
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells)], activeEquipId="home", invGym="home", plates={"kg": {"20": 3, "_ts": 900}}),
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells)], activeEquipId="home", invGym="home"), None),
    ("a sync brought a newer gym copy", "sync",
     S(equipProfiles=[withinv(home, plates={"kg": {"20": 6, "_ts": 500}, "lb": {"45": 2, "_ts": 1}}, dumbbells=bells)], activeEquipId="home", invGym="home",
       plates={"kg": {"20": 2, "_ts": 100}, "lb": {"45": 4, "_ts": 300}}), None, None),
    ("bars by edit stamps, gym newer", "sync",
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells, barDefaults={"barbell": 15}, _f={"barDefaults": 800})], activeEquipId="home", invGym="home",
       barDefaults={"barbell": 20}, edited={"barDefaults": 700}), None, None),
    ("bars by edit stamps, top newer", "sync",
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells, barDefaults={"barbell": 15}, _f={"barDefaults": 600})], activeEquipId="home", invGym="home",
       barDefaults={"barbell": 20}, edited={"barDefaults": 700}), None, None),
    ("an older app switched the gym", "sync",
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells), big], activeEquipId="big", invGym="home", plates={"kg": {"5": 2, "_ts": 10}}), None, None),
    ("active gym gone, owner settles", "sync",
     S(equipProfiles=[withinv(home, plates={"kg": {"20": 9, "_ts": 999}}, dumbbells=bells)], activeEquipId="zzz", invGym="home"), None, None),
    ("session gets its gym", "sync",
     S(equipProfiles=[withinv(noname, plates=plates_kg, dumbbells=bells)], activeEquipId="x", invGym="x", active={"start": 1}), None, None),
    ("an edited workout keeps its gym", "sync",
     S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells)], activeEquipId="home", invGym="home", active={"editingWorkoutId": "w1"}), None, None),
    ("switch", "switch", S(equipProfiles=[withinv(home, plates=plates_kg, dumbbells=bells), big], activeEquipId="home", invGym="home",
                          plates={"kg": {"20": 5, "_ts": 950}}, active={"start": 1, "gym": {"id": "home", "name": "Home"}}), None, "big"),
    ("switch to a gym without lists", "switch", S(equipProfiles=[withinv(big), home], activeEquipId="big", invGym="big"), None, "home"),
    ("switch to the active one", "switch", S(equipProfiles=[withinv(home)], activeEquipId="home", invGym="home"), None, "home"),
    ("switch to no such gym", "switch", S(equipProfiles=[withinv(home)], activeEquipId="home"), None, "nope"),
    ("switch with no bars left", "switch", S(equipProfiles=[withinv(home, barDefaults={"barbell": 15}), withinv(big, barDefaults={})], activeEquipId="home", invGym="home",
                                            barDefaults={"barbell": 15}), None, "big"),
]
out = [{"name": n, "op": op, "state": s, "prev": p, "id": i, "now": NOW} for (n, op, s, p, i) in cases]
p = os.path.join(os.path.dirname(__file__), "../HexplateCore/Tests/HexplateCoreTests/Fixtures/gym-cases.json")
with open(p, "w") as f: json.dump(out, f, indent=1)
print("wrote", len(out), "cases")
