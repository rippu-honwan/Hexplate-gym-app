import json
from pathlib import Path

import pytest

from hexserver.stats import is_warmup, weekly_muscle_sets

FIX = Path(__file__).resolve().parents[2] / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures"
CASES = [(c, g) for c, g in zip(json.loads((FIX / "stats-cases.json").read_text()), json.loads((FIX / "stats-golden.json").read_text()))
         if c["op"] == "stats"]


@pytest.mark.parametrize("case,golden", CASES, ids=[c["name"] for c, _ in CASES])
def test_weekly_muscle_sets_match_opengym(case, golden):
    """Same as openGym's lib/muscle-targets.js weeklyMuscleSets (stats-golden.json, app/scripts/golden.sh)."""
    got = [{k: m[k] for k in ("slug", "sets", "lo", "hi", "status")} for m in weekly_muscle_sets(case["state"], case["today"])]
    assert got == golden["result"]["muscles"]


def test_warmups_by_phase_or_flag():
    assert is_warmup({"phase": "warmup"}) and is_warmup({"warmup": True})
    assert not is_warmup({"phase": "work", "warmup": True}) and not is_warmup({"type": "warmup"})
