import hashlib
import json
import os
import sys
from pathlib import Path

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from hexserver.mcp_server import connect, exercise_history, query, routines, summary
from hexserver.store import Store

FIXTURE = Path(__file__).resolve().parents[2] / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures/history-state.json"


def filled(tmp_path):
    store = Store(tmp_path)
    store.put(json.loads(FIXTURE.read_text()))
    store.db.close()
    return tmp_path


def test_tools(tmp_path):
    db = connect(filled(tmp_path))
    s = summary(db)
    assert s["workouts"] == 4 and s["recent_workouts"][0]["date"] == s["last_date"]
    q = query(db, "SELECT exname(exercise_id) AS name, MAX(e1rm(weight, reps)) FROM sets WHERE done AND NOT warmup GROUP BY 1 ORDER BY 2 DESC")
    assert q["columns"][0] == "name" and q["rows"] and not q["truncated"]
    assert "error" in exercise_history(db, "no such lift")
    r = routines(db)["routines"]
    assert r and r[0]["name"] and all(e["exercise"] for x in r for e in x["exercises"])
    name = q["rows"][0][0]
    assert exercise_history(db, name)["exercise"] == name


def test_read_only(tmp_path):
    db = connect(filled(tmp_path))
    for sql in ["DELETE FROM workouts", "ATTACH 'x.db' AS x", "CREATE TABLE t(a)", "PRAGMA journal_mode=DELETE"]:
        assert query(db, sql)["error"]
    assert query(db, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n")["truncated"]


def test_stdio_handshake(tmp_path):
    folder = filled(tmp_path)
    before = hashlib.md5((folder / "hexplate.sqlite3").read_bytes()).hexdigest()

    async def run():
        params = StdioServerParameters(command=sys.executable, args=["-m", "hexserver", "mcp"],
                                       env={**os.environ, "HEXPLATE_DATA": str(folder)}, cwd=str(Path(__file__).parents[1]))
        async with stdio_client(params) as (r, w), ClientSession(r, w) as session:
            await session.initialize()
            tools = {t.name for t in (await session.list_tools()).tools}
            result = await session.call_tool("get_summary", {})
            return tools, result

    tools, result = anyio.run(run)
    assert tools == {"get_summary", "get_exercise_history", "get_routines", "get_schema", "run_query"}
    assert not result.is_error and '"workouts":4' in result.content[0].text.replace(" ", "")
    assert hashlib.md5((folder / "hexplate.sqlite3").read_bytes()).hexdigest() == before
