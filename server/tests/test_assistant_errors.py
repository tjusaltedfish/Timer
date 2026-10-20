"""Model-service misconfiguration is explained, not reported as unreadable."""
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)
KEY = "sk-relay-0123456789abcdef"


class Relay:
    """A relay that serves its website at the bare host and the API under /v1."""

    def __init__(self, models=("deepseek-v4-flash-1017", "glm-5.3"), status=200):
        self.models, self.status, self.paths = models, status, []

    def __call__(self, request):
        path = request.url.path
        self.paths.append(path)
        if not path.startswith("/v1/"):
            return httpx.Response(200, text="<!doctype html><html>relay home</html>",
                                  headers={"content-type": "text/html; charset=utf-8"})
        if path == "/v1/models":
            return httpx.Response(200, json={"data": [{"id": m} for m in self.models]})
        model = json.loads(request.content)["model"]
        if model not in self.models:
            return httpx.Response(404, json={"error": {"message": f'Model "{model}" is not supported', "type": "model_not_found"}})
        if self.status != 200:
            return httpx.Response(self.status, json={"error": {"message": "Service temporarily unavailable"}})
        return httpx.Response(200, json={"choices": [{"message": {"content": "在的"}}]})


def make(tmp_path, monkeypatch, relay):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(relay), background=False)
    client = TestClient(app)
    client.__enter__()
    client.headers["Authorization"] = "Bearer " + app.state.desktop_token
    return client


@pytest.fixture
def relay():
    return Relay()


def configure(client, base, model):
    assert client.post("/api/v1/assistant/config", json={"base_url": base, "model": model, "api_key": KEY}).status_code == 200


def test_missing_v1_is_detected_and_fixed_by_the_connection_test(tmp_path, monkeypatch, relay):
    client = make(tmp_path, monkeypatch, relay)
    configure(client, "https://relay.example", "deepseek-v4-flash-1017")
    chat = client.post("/api/v1/assistant/messages", json={"text": "hi"})
    assert chat.status_code == 502 and "/v1" in chat.json()["message"]
    tested = client.post("/api/v1/assistant/test").json()
    assert tested["ok"] is True and tested["fixed_base_url"] == "https://relay.example/v1"
    assert client.get("/api/v1/assistant/config").json()["base_url"] == "https://relay.example/v1"


def test_unknown_model_lists_what_the_service_offers(tmp_path, monkeypatch, relay):
    client = make(tmp_path, monkeypatch, relay)
    configure(client, "https://relay.example/v1", "deepseek-v4-flash")
    tested = client.post("/api/v1/assistant/test")
    message = tested.json()["message"]
    assert tested.status_code == 502 and "deepseek-v4-flash" in message and "deepseek-v4-flash-1017" in message
    assert client.get("/api/v1/assistant/models").json()["models"] == ["deepseek-v4-flash-1017", "glm-5.3"]


def test_outage_carries_the_relay_reason_and_never_the_key(tmp_path, monkeypatch):
    client = make(tmp_path, monkeypatch, Relay(status=503))
    configure(client, "https://relay.example/v1", "deepseek-v4-flash-1017")
    tested = client.post("/api/v1/assistant/test")
    assert tested.status_code == 502
    assert "503" in tested.json()["message"] and "Service temporarily unavailable" in tested.json()["message"]
    assert KEY not in tested.text
