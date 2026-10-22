"""v2 P2: each person gets their own assistant, key, history, drafts and usage."""
import json
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant, auth
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 in Los Angeles
PASSWORD = "correct-horse-9"
OWNER_KEY = "sk-owner-0123456789abcdef"
MEMBER_KEY = "sk-member-fedcba9876543210"


class FakeModel:
    def __init__(self):
        self.replies, self.requests = [], []

    def __call__(self, request):
        self.requests.append(request)
        status, body = self.replies.pop(0) if self.replies else (200, {"reply": "好的", "drafts": []})
        content = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    return FakeModel()


@pytest.fixture
def app(tmp_path, model):
    return create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model))


@pytest.fixture
def client(app):
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def make_user(app, username="shidi", password=PASSWORD):
    with app.state.store.connect() as conn:
        user = auth.create_user(conn, username=username, password=password, display_name=username)
        app.state.store.save(conn, app.state.store.initial_state(), user["id"])
    return user


def login(client, username, password=PASSWORD):
    response = client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": password, "device": {"name": "手机", "platform": "android"}},
    )
    assert response.status_code == 200, response.text
    return response.json()["token"]


def bearer(token):
    return {"Authorization": "Bearer " + token}


def configure(client, token=None, key=OWNER_KEY, **extra):
    body = {"base_url": "https://relay.example/v1", "model": "deepseek-chat", "api_key": key, **extra}
    response = client.post("/api/v1/assistant/config", json=body, headers=bearer(token) if token else None)
    assert response.status_code == 200, response.text
    return response.json()


def snapshot(client, token=None):
    return client.get("/api/v1/snapshot", headers=bearer(token) if token else None).json()


def test_two_users_have_separate_assistants_history_and_usage(client, app, model):
    make_user(app)
    member = login(client, "shidi")
    configure(client)
    configure(client, member, key=MEMBER_KEY)
    model.replies += [(200, {"reply": "主人你好", "drafts": []}),
                      (200, {"reply": "师弟你好", "drafts": []})]
    assert client.post("/api/v1/assistant/messages", json={"text": "你是谁"}).status_code == 200
    assert client.post("/api/v1/assistant/messages", json={"text": "你是谁"}, headers=bearer(member)).status_code == 200

    owner_history = client.get("/api/v1/assistant/messages").json()["messages"]
    member_history = client.get("/api/v1/assistant/messages", headers=bearer(member)).json()["messages"]
    assert owner_history[-1]["text"] == "主人你好"
    assert member_history[-1]["text"] == "师弟你好"
    assert [row["text"] for row in member_history if row["role"] == "user"] == ["你是谁"]
    assert len([row for row in owner_history if row["role"] == "user"]) == 1

    owner_conf = client.get("/api/v1/assistant/config").json()
    member_conf = client.get("/api/v1/assistant/config", headers=bearer(member)).json()
    assert owner_conf["used_today"] == member_conf["used_today"] == 1
    assert owner_conf["key_hint"] != member_conf["key_hint"]
    assert member_conf["key_hint"] == "····3210"


def test_member_draft_changes_only_the_members_schedule(client, app, model):
    make_user(app)
    member = login(client, "shidi")
    configure(client, member, key=MEMBER_KEY, confirm_first=True)
    model.replies.append((200, {"reply": "拟办如下。", "drafts": [{"summary": "学算法", "actions": [
        {"type": "schedule_new", "title": "学习算法", "outcome_criteria": "跑通两个例子",
         "start_local": "2026-10-19 10:00", "minutes": 60}]}]}))
    reply = client.post("/api/v1/assistant/messages", json={"text": "十点学算法"},
                        headers=bearer(member)).json()["messages"][-1]
    draft_id = reply["drafts"][0]["id"]
    assert snapshot(client)["blocks"] == []
    applied = client.post(f"/api/v1/assistant/drafts/{draft_id}/apply", headers=bearer(member))
    assert applied.status_code == 200, applied.text
    assert [block["title"] for block in snapshot(client, member)["blocks"]] == ["学习算法"]
    assert snapshot(client)["blocks"] == []
    # The owner's token cannot reach a draft that belongs to another account.
    assert client.post(f"/api/v1/assistant/drafts/{draft_id}/apply").status_code == 404
    assert client.post(f"/api/v1/assistant/drafts/{draft_id}/dismiss").status_code == 404


def test_persona_is_part_of_each_persons_config(client, app):
    make_user(app)
    member = login(client, "shidi")
    conf = configure(client, member, key=MEMBER_KEY, persona="老师")
    assert conf["persona"] == "老师"
    bad = client.post("/api/v1/assistant/config", json={"persona": "陌生人"}, headers=bearer(member))
    assert bad.status_code == 422


def test_the_owners_v1_key_files_are_imported_once(tmp_path, model):
    (tmp_path / "secrets").mkdir()
    (tmp_path / "assistant.json").write_text(json.dumps({
        "base_url": "https://relay.example/v1", "model": "deepseek-chat",
        "daily_limit": 50, "timeout_seconds": 45, "confirm_first": False,
    }), encoding="utf-8")
    (tmp_path / "secrets" / "llm-key").write_text(OWNER_KEY, encoding="utf-8")
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model))
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        conf = client.get("/api/v1/assistant/config").json()
        assert conf["configured"] is True
        assert conf["model"] == "deepseek-chat" and conf["daily_limit"] == 50
        assert conf["key_hint"] == "····cdef" and conf["key_source"] == "user"
        # The imported key is sealed in the database, not stored as plain text.
        assert OWNER_KEY.encode() not in (tmp_path / "planner.db").read_bytes()
