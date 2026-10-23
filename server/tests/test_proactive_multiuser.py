"""Notifications belong to the account whose schedule produced them.

The reported bug: after the WeChat/QQ handle was rebound from the owner to a
second person, the owner's proactive reminders ("该开始了 · 秋招准备") were still
sent to that handle.  One cursor plus one bound openid made every account share
the owner's chat target.  These tests pin down per-account routing.
"""
import json
import os
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant, auth
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 Los Angeles
OWNER_OPENID = "o_owner_openid_1234"
MEMBER_OPENID = "o_member_openid_5678"
OWNER, MEMBER = "owner-password-123", "member-password-123"


class FakeWeChat:
    def __init__(self):
        self.custom = []

    def __call__(self, request):
        path = request.url.path
        if path == "/cgi-bin/stable_token":
            return httpx.Response(200, json={"access_token": "T", "expires_in": 7200})
        if path == "/cgi-bin/message/custom/send":
            body = json.loads(request.content or b"{}")
            self.custom.append((request.url.params["access_token"], body))
            return httpx.Response(200, json={"errcode": 0, "errmsg": "ok"})
        return httpx.Response(404)


class FakeModel:
    def __call__(self, request):
        return httpx.Response(200, json={"choices": [{"message": {"content": '{"reply":"好","drafts":[]}'}}]})


def operation(client, kind, **payload):
    response = client.post("/api/v1/operations", json={"operation_id": os.urandom(16).hex(), "kind": kind,
                                                       "payload": payload})
    assert response.status_code == 200, response.text
    return response.json()["entity"]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    wechat, model = FakeWeChat(), FakeModel()
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model),
                     wechat_transport=httpx.MockTransport(wechat), background=False)
    with TestClient(app) as owner_client:
        owner_client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        owner_client.post("/api/v1/wechat/config", json={"app_id": "wx0123456789abcdef", "app_secret": "ab" * 16})
        with app.state.store.connect() as conn:
            auth.set_registration(conn, True)
        response = owner_client.post("/api/v1/auth/register", json={
            "username": "shidi", "password": MEMBER, "display_name": "师弟",
            "timezone": "Asia/Shanghai", "device": {"name": "手机", "platform": "android"}})
        assert response.status_code == 200, response.text
        member_token = response.json()["token"]
        member_id = response.json()["user"]["id"]
        owner_id = app.state.store.owner_id
        with app.state.store.connect() as conn:
            app.state.wechat.identities.bind(conn, "wechat", OWNER_OPENID, owner_id, "主账号")
            app.state.wechat.identities.bind(conn, "wechat", MEMBER_OPENID, member_id, "师弟")
        member_client = TestClient(app)
        member_client.headers["Authorization"] = "Bearer " + member_token
        yield app, owner_client, member_client, wechat, owner_id, member_id


def queued(app, since=0):
    with app.state.store.connect() as conn:
        return [dict(row) for row in conn.execute(
            "SELECT dedup_key, openid, text, status FROM wechat_outbox ORDER BY rowid")][since:]


def test_each_account_is_notified_on_its_own_handle(world):
    app, owner, member, wechat, owner_id, member_id = world
    operation(owner, "task.create", id="owner-task", title="秋招准备", outcome_criteria="投完三家", remaining_minutes=90)
    operation(member, "task.create", id="member-task", title="学习具身智能", outcome_criteria="跑通 demo", remaining_minutes=90)
    start = since = len(queued(app))
    app.state.proactive.tick()
    rows = queued(app, since)
    assert rows, "通知应该写进发件箱"
    owner_texts = [r["text"] for r in rows if r["openid"] == OWNER_OPENID]
    member_texts = [r["text"] for r in rows if r["openid"] == MEMBER_OPENID]
    assert any("秋招准备" in t for t in owner_texts)
    assert not any("秋招准备" in t for t in member_texts), "主账号的待办不能发给师弟"
    assert any("学习具身智能" in t for t in member_texts)
    assert not any("学习具身智能" in t for t in owner_texts)
    # dedupe keys carry the account, so two people's identical reminders never collapse.
    assert all(str(owner_id) in r["dedup_key"] for r in rows if r["openid"] == OWNER_OPENID)
    assert all(str(member_id) in r["dedup_key"] for r in rows if r["openid"] == MEMBER_OPENID)


def test_delivery_sends_member_reminder_to_the_member_handle(world):
    app, owner, member, wechat, owner_id, member_id = world
    operation(member, "task.create", id="member-task", title="学习具身智能", outcome_criteria="跑通 demo", remaining_minutes=60)
    app.state.proactive.tick()
    owner.portal.call(app.state.wechat.run_once)
    bodies = [body for _, body in wechat.custom]
    mine = [b for b in bodies if b.get("touser") == MEMBER_OPENID]
    assert mine and any("学习具身智能" in b["text"]["content"] for b in mine)
    assert not [b for b in bodies if b.get("touser") == OWNER_OPENID and "学习具身智能" in b["text"]["content"]]


def test_a_rebound_handle_only_receives_its_new_account(world):
    """The exact reported symptom: the owner's reminder must not follow the handle."""
    app, owner, member, wechat, owner_id, member_id = world
    with app.state.store.connect() as conn:
        app.state.wechat.identities.bind(conn, "wechat", OWNER_OPENID, member_id, "师弟")
    operation(owner, "task.create", id="owner-task", title="秋招准备", outcome_criteria="投完三家", remaining_minutes=90)
    operation(member, "task.create", id="member-task", title="学习具身智能", outcome_criteria="跑通 demo", remaining_minutes=90)
    since = len(queued(app))
    app.state.proactive.tick()
    rows = queued(app, since)
    assert rows and all(r["openid"] in (OWNER_OPENID, MEMBER_OPENID) for r in rows)
    assert any("学习具身智能" in r["text"] for r in rows)
    assert not any("秋招准备" in r["text"] for r in rows), "改绑后不能把原账号的提醒发给现主人"


def test_single_account_still_uses_the_legacy_binding(world):
    """Owner keeps working through the v1 file binding when no identity row exists."""
    app, owner, member, wechat, owner_id, member_id = world
    with app.state.store.connect() as conn:
        conn.execute("DELETE FROM channel_identities WHERE channel='wechat' AND external_id=?", (OWNER_OPENID,))
    settings = app.state.wechat.settings
    settings.save({**settings.load(), "bound_openid": OWNER_OPENID})
    operation(owner, "task.create", id="owner-task", title="秋招准备", outcome_criteria="投完三家", remaining_minutes=90)
    since = len(queued(app))
    app.state.proactive.tick()
    rows = queued(app, since)
    assert rows and all(r["openid"] == OWNER_OPENID for r in rows)
    assert any("秋招准备" in r["text"] for r in rows)
