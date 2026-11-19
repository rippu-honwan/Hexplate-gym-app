import pytest
from fastapi.testclient import TestClient

from hexserver.app import create_app


@pytest.fixture
def client(tmp_path):
    return TestClient(create_app(tmp_path))


@pytest.fixture
def phone(client):
    """A client paired the way the app pairs (POST /api/pair/redeem)."""
    code = client.app.state.store.new_pair_code()
    r = client.post("/api/pair/redeem", json={"code": code.lower()})
    assert r.status_code == 200 and r.json()["user"]["id"]
    client.headers["Authorization"] = "Bearer " + r.json()["token"]
    return client
