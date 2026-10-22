"""The phone reports real client-side auth failures to the desktop log.

Release packages cannot write logcat, so this endpoint is the only way to see
why a login failed on the device. It must never break the request itself.
"""
import json
from datetime import datetime, timezone

import httpx
from fastapi.testclient import TestClient

from app.main import create_app

NOW = datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc)


def make(tmp_path):
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(lambda _: None), background=False)
    return app, TestClient(app)


def test_client_log_appends_a_json_line(tmp_path):
    app, client = make(tmp_path)
    with client:
        response = client.post(
            "/api/v1/client-log",
            json={"source": "client-auth", "version": "1.2.6+16", "message": "boom"},
        )
    assert response.status_code == 200
    assert response.json()["ok"] is True
    path = tmp_path / "client_errors.log"
    assert path.exists()
    entry = json.loads(path.read_text(encoding="utf-8").splitlines()[-1])
    assert entry["source"] == "client-auth"
    assert entry["message"] == "boom"
    assert entry["at"]


def test_client_log_ignores_junk_without_failing(tmp_path):
    app, client = make(tmp_path)
    with client:
        response = client.post("/api/v1/client-log", json={"source": 7, "message": ["x"]})
    assert response.status_code == 200
    entry = json.loads((tmp_path / "client_errors.log").read_text(encoding="utf-8").splitlines()[-1])
    assert "source" not in entry
