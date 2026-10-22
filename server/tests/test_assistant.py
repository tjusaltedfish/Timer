"""Assistant configuration and drafts, against a mocked OpenAI-compatible service."""
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
        yield value


def configure(client, **extra):
    body = {"base_url": "https://relay.example/v1/", "model": "deepseek-chat", "api_key": SECRET,
            "confirm_first": True, **extra}
    response = client.post("/api/v1/assistant/config", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def send(client, kind, **payload):
    response = client.post("/api/v1/operations", json={"operation_id": str(uuid4()), "kind": kind, "payload": payload})
    assert response.status_code == 200, response.text
    return response.json()["entity"]


def test_config_keeps_key_on_this_computer(client, tmp_path):
    assert client.get("/api/v1/assistant/config").json()["configured"] is False
    public = configure(client)
    assert public["configured"] is True
    assert public["base_url"] == "https://relay.example/v1"
    assert public["key_hint"] == "····cdef"
    assert SECRET not in json.dumps(public)
    assert SECRET not in (tmp_path / "assistant.json").read_text(encoding="utf-8")
    assert (tmp_path / "secrets" / "llm-key").read_text(encoding="utf-8") == SECRET
    # Leaving the key out keeps it; clearing removes it.
    assert configure(client, api_key=None)["key_hint"] == "····cdef"
    assert client.post("/api/v1/assistant/config", json={"clear_key": True}).json()["configured"] is False
    bad = client.post("/api/v1/assistant/config", json={"base_url": "ftp://x"})
    assert bad.status_code == 422


def test_phone_cannot_change_assistant_config(client):
    code = client.post("/api/v1/pairing/code").json()["code"]
    token = client.post("/api/v1/pairing/confirm", json={"code": code, "name": "手机"}).json()["token"]
    phone = {"Authorization": "Bearer " + token}
    assert client.post("/api/v1/assistant/config", json={"model": "x"}, headers=phone).status_code == 403
    assert client.get("/api/v1/assistant/config", headers=phone).status_code == 200


def test_connection_test_reports_auth_failure_without_leaking_key(client, model):
    configure(client)
    model.replies.append((200, "在的"))
    ok = client.post("/api/v1/assistant/test").json()
    assert ok["ok"] is True and ok["reply"] == "在的"
    sent = model.requests[-1]
    assert str(sent.url) == "https://relay.example/v1/chat/completions"
    assert sent.headers["authorization"] == "Bearer " + SECRET
    model.replies.append((401, None))
    failed = client.post("/api/v1/assistant/test")
    assert failed.status_code == 502
    assert SECRET not in failed.text


def test_unconfigured_assistant_explains_itself(client):
    response = client.post("/api/v1/assistant/messages", json={"text": "明天上午安排写代码"})
    assert response.status_code == 409
    assert "设置" in response.json()["message"]


def test_draft_applies_only_after_confirmation(client, model):
    configure(client)
    category = send(client, "project.create", name="实验代码")
    model.replies.append((200, {"reply": "拟办如下。", "drafts": [{"summary": "明早写扫描脚本", "actions": [
        {"type": "schedule_new", "title": "参数扫描脚本", "outcome_criteria": "输出可复现 CSV",
         "project": "c1", "start_local": "2026-10-20 10:00", "minutes": 90}]}]}))
    reply = client.post("/api/v1/assistant/messages", json={"text": "明早十点写扫描脚本"}).json()["messages"]
    assert [m["role"] for m in reply] == ["user", "assistant"]
    draft = reply[1]["drafts"][0]
    assert draft["status"] == "pending"
    assert "10/20" in draft["lines"][0] and "10:00–11:30" in draft["lines"][0]
    # The model never sees real ids, and nothing changed yet.
    assert client.get("/api/v1/snapshot").json()["blocks"] == []
    applied = client.post(f"/api/v1/assistant/drafts/{draft['id']}/apply").json()
    assert applied["applied"] == ["task.create", "block.create"]
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["blocks"][0]["start_at"] == "2026-10-20T17:00:00+00:00"
    assert snapshot["tasks"][0]["outcome_criteria"] == "输出可复现 CSV"
    assert snapshot["tasks"][0]["project_id"] == category["id"]
    context = json.loads(model.requests[-1].content)["messages"][1]["content"]
    assert "c1 实验代码" in context and category["id"] not in context
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/apply").status_code == 409
    history = client.get("/api/v1/assistant/messages").json()["messages"]
    assert history[-1]["drafts"][0]["status"] == "applied"


def test_past_times_and_unknown_ids_never_become_drafts(client, model):
    configure(client)
    model.replies.append((200, {"reply": "好", "drafts": [
        {"summary": "过去", "actions": [{"type": "protect", "title": "午饭", "start_local": "2026-10-19 08:00", "minutes": 30}]},
        {"summary": "瞎编", "actions": [{"type": "move_block", "block": "b9", "start_local": "2026-10-20 08:00"}]}]}))
    reply = client.post("/api/v1/assistant/messages", json={"text": "?"}).json()["messages"][1]
    assert reply["drafts"] == []
    assert "已经过去" in reply["text"] and "不存在" in reply["text"]


def test_move_uses_short_ids_and_keeps_duration(client, model):
    configure(client)
    task = send(client, "task.create", title="投递整理", outcome_criteria="更新表格", remaining_minutes=60)
    block = send(client, "block.create", task_id=task["id"], start_at="2026-10-19T20:00:00+00:00",
                 end_at="2026-10-19T21:00:00+00:00")
    model.replies.append((200, {"reply": "挪到下午", "drafts": [{"summary": "顺延", "actions": [
        {"type": "move_block", "block": "b1", "start_local": "2026-10-19 15:00"}]}]}))
    reply = client.post("/api/v1/assistant/messages", json={"text": "推迟两小时"}).json()["messages"][1]
    context = json.loads(model.requests[-1].content)["messages"][1]["content"]
    assert "b1｜" in context and block["id"] not in context
    client.post(f"/api/v1/assistant/drafts/{reply['drafts'][0]['id']}/apply")
    moved = client.get("/api/v1/snapshot").json()["blocks"][0]
    assert (moved["start_at"], moved["end_at"]) == ("2026-10-19T22:00:00+00:00", "2026-10-19T23:00:00+00:00")


def test_invalid_json_is_retried_once_then_answered_plainly(client, model):
    configure(client)
    model.replies += [(200, "not json"), (200, {"reply": "明白了", "drafts": []})]
    reply = client.post("/api/v1/assistant/messages", json={"text": "hi"}).json()["messages"][1]
    assert reply["text"] == "明白了"
    assert len(model.requests) == 2


def test_daily_limit_and_service_outage(client, model):
    configure(client, daily_limit=1)
    model.replies += [(503, None)] * 3
    assert client.post("/api/v1/assistant/messages", json={"text": "hi"}).status_code == 502
    assert client.post("/api/v1/assistant/messages", json={"text": "hi"}).status_code == 200
    assert client.post("/api/v1/assistant/messages", json={"text": "hi"}).status_code == 429


def test_a_blank_reply_is_asked_again(client, model):
    """这个模型偶尔把正文全花在思考上、content 只回空白：要当成一次可重试的失败。"""
    configure(client)
    model.replies += [(200, "   "), (200, {"reply": "这轮想清楚了。", "drafts": []})]
    reply = client.post("/api/v1/assistant/messages", json={"text": "在吗"}).json()["messages"][1]
    assert reply["text"] == "这轮想清楚了。"
    assert len(model.requests) == 2


def test_a_blank_reply_that_keeps_blank_becomes_a_plain_answer(client, model):
    configure(client)
    model.replies += [(200, ""), (200, ""), (200, "")][:3]
    reply = client.post("/api/v1/assistant/messages", json={"text": "在吗"})
    assert reply.status_code == 502
    assert "再问一次" in reply.json()["message"]
