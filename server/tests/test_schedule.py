"""schedule.py against the golden files the app's own tests use (written by app/scripts/golden.sh
from openGym's JavaScript): the plan per day, the week's tally and goal, and the streak."""
import json
from pathlib import Path

import pytest

from hexserver import schedule as S

FIX = Path(__file__).resolve().parents[2] / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures"
SCHEDULE = list(zip(json.loads((FIX / "schedule-cases.json").read_text()), json.loads((FIX / "schedule-golden.json").read_text())))
WIDGET = list(zip(json.loads((FIX / "widget-cases.json").read_text()), json.loads((FIX / "widget-golden.json").read_text())))
CLONE_SCHEDULE = json.loads((FIX / "clone-schedule-cases.json").read_text())["cases"]


@pytest.mark.parametrize("case,gold", SCHEDULE, ids=[c["name"] for c, _ in SCHEDULE])
def test_schedule_reads(case, gold):
    s, today, want = case["state"], case["today"], gold["steps"][0]["reads"]
    assert [{"iso": d["iso"], "ids": S.routine_ids(s, d["iso"], today)} for d in want["days"]] == want["days"]
    assert S.schedule_mode(s) == want["mode"]
    assert S.week_tally(s, today) == want["tally"]
    assert S.workouts_left(s, today) == want["left"]


@pytest.mark.parametrize("case", CLONE_SCHEDULE, ids=[c["name"] for c in CLONE_SCHEDULE])
def test_clone_schedule_parity(case):
    """Shared hand-written Swift/Python parity cases for Clone-and-Pin schedule resolution (T8)."""
    s, today = case["state"], case["today"]
    for raw_id, expected in case.get("canonical", {}).items():
        assert S._canonical(s, raw_id) == expected
    assert [{"iso": d["iso"], "ids": S.routine_ids(s, d["iso"], today)} for d in case["days"]] == case["days"]


@pytest.mark.parametrize("case,gold", WIDGET, ids=[c["name"] for c, _ in WIDGET])
def test_streak(case, gold):
    assert S.streak(case["state"], case["today"]) == gold["result"]["streakInfo"]
