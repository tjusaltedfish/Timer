"""One member's slow model call must not block another member's message.

The channel workers used to walk the inbox one row at a time and wait for the
whole model round-trip (up to the configured timeout, 45s by default). With two
or three people sharing one bot, a single hard question held everybody else's
messages hostage. Rows are now grouped by account: each account keeps its own
arrival order, different accounts are answered in parallel.
"""
import asyncio
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import auth
from app.channel_identity import IdentityStore
from app.main import create_app

PASSWORD = "correct-horse-9"
OWNER_OPENID = "o_owner_concurrency"
SHIDI_OPENID = "o_shidi_concurrency"
NOW = "2026-10-19T16:00:00Z"

def clock_now():
    return datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)


class SlowModel:
    """Answers after a short wait and remembers how many calls overlapped."""

    def __init__(self):
        self.active = 0
        self.max_active = 0
        self.calls = 0

    async def __call__(self, request):
        self.calls += 1
        self.active += 1
        self.max_active = max(self.max_active, self.active)
        try:
            await asyncio.sleep(0.2)
            content = json.dumps({"reply": "好", "drafts": []}, ensure_ascii=False)
            return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})
        finally:
            self.active -= 1


@pytest.fixture
def env(tmp_path, monkeypatch):
    from app import assistant
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    model = SlowModel()
    app = create_app(tmp_path, clock=clock_now, llm_transport=httpx.MockTransport(model), background=False)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        with app.state.store.connect() as conn:
            shidi = auth.create_user(conn, username="shidi", password=PASSWORD, display_name="师弟")
            app.state.store.save(conn, app.state.store.initial_state(), shidi["id"])
            identities = IdentityStore(app.state.store, clock_now)
            identities.bind(conn, "wechat", OWNER_OPENID, app.state.store.owner_id, "owner")
            identities.bind(conn, "wechat", SHIDI_OPENID, shidi["id"], "师弟")
        yield client, app, model


def configure_assistant(client, token=None):
    response = client.post(
        "/api/v1/assistant/config",
        json={"base_url": "https://llm.example/v1", "model": "m", "api_key": "sk-test-1234567890"},
        headers={"Authorization": "Bearer " + token} if token else None,
    )
    assert response.status_code == 200, response.text
    return response


def login(client, username):
    response = client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": PASSWORD, "device": {"name": "手机", "platform": "android"}},
    )
    assert response.status_code == 200, response.text
    return response.json()["token"]


def push_rows(app, *rows):
    with app.state.store.connect() as conn:
        for index, (openid, content) in enumerate(rows):
            conn.execute("INSERT INTO wechat_inbox(id, dedup_key, openid, kind, content, received_at, status) "
                         "VALUES(?,?,?,?,?,?, 'pending')",
                         (f"row-{index}", f"concurrent-{index}-{openid}", openid, "text", content, NOW))


def test_two_members_are_answered_at_the_same_time(env):
    client, app, model = env
    configure_assistant(client)
    configure_assistant(client, login(client, "shidi"))
    push_rows(app, (OWNER_OPENID, "你好呀，今天怎么样"), (SHIDI_OPENID, "帮我看下今天"))

    asyncio.run(app.state.wechat.run_once())

    assert model.calls == 2
    assert model.max_active == 2, "两个账号的模型调用应当重叠，而不是排队"
    with app.state.store.connect() as conn:
        statuses = [row["status"] for row in conn.execute("SELECT status FROM wechat_inbox ORDER BY rowid")]
        assert statuses == ["done", "done"]
        replies = [row["text"] for row in conn.execute(
            "SELECT text FROM wechat_outbox WHERE status='queued' ORDER BY rowid")]
    assert replies == ["好", "好"]


def test_unbound_sender_is_explained_without_calling_the_model(env):
    client, app, model = env
    configure_assistant(client)
    push_rows(app, ("o_stranger_concurrency", "你好"))

    asyncio.run(app.state.wechat.run_once())

    assert model.calls == 0
    with app.state.store.connect() as conn:
        row = conn.execute("SELECT status, note FROM wechat_inbox").fetchone()
    assert (row["status"], row["note"]) == ("done", "unbound")
