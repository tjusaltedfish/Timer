"""大改动在「直接执行」模式下也要先确认（plan §9.3 护栏）。"""
import json
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 in Los Angeles
SECRET = "sk-test-0123456789abcdef"


class FakeModel:
    def __init__(self):
        self.replies, self.requests = [], []

    def __call__(self, request):
        self.requests.append(request)
        status, body = self.replies.pop(0) if self.replies else (200, {"reply": "好的", "drafts": []})
        if status != 200:
            return httpx.Response(status, json={"error": {"message": "nope"}})
        content = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    return FakeModel()


@pytest.fixture
def client(tmp_path, model):
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model))
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        value.post("/api/v1/assistant/config", json={
            "base_url": "https://relay.example/v1", "model": "deepseek-chat",
            "api_key": SECRET, "confirm_first": False})
        yield value


def send(client, kind, **payload):
    response = client.post("/api/v1/operations", json={"operation_id": str(uuid4()), "kind": kind, "payload": payload})
    assert response.status_code == 200, response.text
    return response.json()["entity"]


def turn(client, text):
    response = client.post("/api/v1/assistant/messages", json={"text": text})
    assert response.status_code == 200, response.text
    return response.json()["messages"][-1]


def test_cancelling_four_things_asks_before_doing_it(client, model):
    tasks = [send(client, "task.create", title=f"待办{i}", outcome_criteria="做完", remaining_minutes=30)
             for i in range(4)]
    actions = [{"type": "cancel_task", "task": f"t{index}"} for index in range(1, 5)]
    model.replies.append((200, {"reply": "都撤了。", "drafts": [{"summary": "撤掉四件", "actions": actions}]}))

    reply = turn(client, "把刚才那四件都撤掉")
    assert "确认" in reply["text"]
    assert reply["drafts"][0]["status"] == "pending"
    snapshot = client.get("/api/v1/snapshot").json()
    assert [task["state"] for task in snapshot["tasks"]] == ["ready"] * 4

    applied = client.post(f"/api/v1/assistant/drafts/{reply['drafts'][0]['id']}/apply").json()
    assert applied["applied"] == ["task.update"] * 4
    assert [task["state"] for task in client.get("/api/v1/snapshot").json()["tasks"]] == ["cancelled"] * 4


def test_a_small_change_still_runs_without_asking(client, model):
    send(client, "task.create", title="写报告", outcome_criteria="初稿", remaining_minutes=60)
    model.replies.append((200, {"reply": "好，撤了。", "drafts": [{
        "summary": "撤掉写报告", "actions": [{"type": "cancel_task", "task": "t1"}]}]}))
    reply = turn(client, "写报告这事先不做了")
    assert "确认" not in reply["text"]
    assert client.get("/api/v1/snapshot").json()["tasks"][0]["state"] == "cancelled"


def test_arranging_two_different_days_asks_before_doing_it(client, model):
    model.replies.append((200, {"reply": "排好了。", "drafts": [{
        "summary": "两天各排一段", "actions": [
            {"type": "schedule_new", "title": "读论文", "outcome_criteria": "读完引言",
             "start_local": "2026-10-20 10:00", "minutes": 60},
            {"type": "schedule_new", "title": "写代码", "outcome_criteria": "跑通",
             "start_local": "2026-10-21 10:00", "minutes": 60}]}]}))
    reply = turn(client, "明后天各给我排一小时")
    assert "确认" in reply["text"]
    assert reply["drafts"][0]["status"] == "pending"
    assert client.get("/api/v1/snapshot").json()["blocks"] == []

