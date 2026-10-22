"""One WeChat official account, several people: each follower binds to one account."""
import hashlib
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant, auth
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 Los Angeles
PASSWORD = "correct-horse-9"
APP_SECRET = "0123456789abcdef0123456789abcdef"


class FakeWeChat:
    def __init__(self):
        self.custom = []
        self.template = []

    def __call__(self, request):
        path = request.url.path
        body = json.loads(request.content or b"{}")
        if path == "/cgi-bin/stable_token":
            return httpx.Response(200, json={"access_token": "T1", "expires_in": 7200})
        if path == "/cgi-bin/message/custom/send":
            self.custom.append(body)
            return httpx.Response(200, json={"errcode": 0, "errmsg": "ok"})
        if path == "/cgi-bin/message/template/send":
            self.template.append(body)
            return httpx.Response(200, json={"errcode": 0, "errmsg": "ok"})
        return httpx.Response(404)


class FakeModel:
    def __init__(self):
        self.replies, self.requests = [], []

    def __call__(self, request):
        self.requests.append(request)
        body = self.replies.pop(0) if self.replies else {"reply": "好的", "drafts": []}
        content = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    wechat, model = FakeWeChat(), FakeModel()
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model),
                     wechat_transport=httpx.MockTransport(wechat), background=False)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        client.post("/api/v1/wechat/config", json={"app_id": "wx0123456789abcdef", "app_secret": APP_SECRET})
        yield client, app, wechat, model


def make_user(app, username="shidi", password=PASSWORD):
    with app.state.store.connect() as conn:
        user = auth.create_user(conn, username=username, password=password, display_name=username)
        app.state.store.save(conn, app.state.store.initial_state(), user["id"])
    return user


def login(client, username, password=PASSWORD):
    response = client.post("/api/v1/auth/login", json={
        "username": username, "password": password, "device": {"name": "手机", "platform": "android"}})
    assert response.status_code == 200, response.text
    return response.json()["token"]


def bearer(token):
    return {"Authorization": "Bearer " + token}


def signed(token, nonce="n1", at=NOW):
    timestamp = str(int(at.timestamp()))
    signature = hashlib.sha1("".join(sorted([token, timestamp, nonce])).encode()).hexdigest()
    return {"signature": signature, "timestamp": timestamp, "nonce": nonce}


def push(client, token, sender, content, msg_id="1", kind="text", event=None):
    fields = f"<ToUserName><![CDATA[gh_test]]></ToUserName><FromUserName><![CDATA[{sender}]]></FromUserName>" \
             f"<CreateTime>{int(NOW.timestamp())}</CreateTime><MsgType><![CDATA[{kind}]]></MsgType>"
    if content is not None:
        fields += f"<Content><![CDATA[{content}]]></Content><MsgId>{msg_id}</MsgId>"
    if event:
        fields += f"<Event><![CDATA[{event}]]></Event>"
    response = client.post("/wechat/callback", params=signed(token), content=f"<xml>{fields}</xml>".encode())
    assert response.status_code == 200 and response.text == "success"


def run(client, app):
    client.portal.call(app.state.wechat.run_once)


def bound_token(client):
    return client.get("/api/v1/wechat/config").json()["token"]


def test_a_member_binds_their_own_wechat_and_commands_hit_their_own_state(env):
    client, app, wechat, _ = env
    make_user(app)
    member = login(client, "shidi")
    code = client.post("/api/v1/channels/wechat/bind-code", headers=bearer(member)).json()["code"]
    push(client, bound_token(client), "o_shidi", code, msg_id="m1")
    run(client, app)
    assert any("绑定好了" in body["text"]["content"] for body in wechat.custom)

    push(client, bound_token(client), "o_shidi", "记住：周日上午跑 LSD", msg_id="m2")
    run(client, app)
    assert [row["text"] for row in client.get("/api/v1/snapshot", headers=bearer(member)).json().get("memories", [])] \
        == ["周日上午跑 LSD"]
    assert client.get("/api/v1/snapshot").json().get("memories", []) == []
    push(client, bound_token(client), "o_shidi", "今天", msg_id="m3")
    run(client, app)
    assert "还没有安排" in wechat.custom[-1]["text"]["content"]


def test_an_unbound_follower_is_told_how_to_bind_once(env):
    client, app, wechat, _ = env
    push(client, bound_token(client), "o_stranger", "你好", msg_id="m1")
    run(client, app)
    assert "还没绑定瞬时账号" in wechat.custom[-1]["text"]["content"]
    with app.state.store.connect() as conn:
        row = conn.execute("SELECT status FROM wechat_inbox ORDER BY rowid DESC LIMIT 1").fetchone()
    assert row["status"] == "done"


def test_a_code_is_single_use_and_cannot_steal_an_existing_binding(env):
    client, app, wechat, _ = env
    make_user(app)
    member = login(client, "shidi")
    code = client.post("/api/v1/channels/wechat/bind-code", headers=bearer(member)).json()["code"]
    push(client, bound_token(client), "o_a", code, msg_id="m1")
    run(client, app)
    push(client, bound_token(client), "o_b", code, msg_id="m2")
    run(client, app)
    assert "用过了" in wechat.custom[-1]["text"]["content"]
    # o_a is already shidi's: an owner code sent from it is just chat, never a rebind.
    owner_code = client.post("/api/v1/channels/wechat/bind-code").json()["code"]
    push(client, bound_token(client), "o_a", owner_code, msg_id="m3")
    run(client, app)
    assert client.get("/api/v1/channels/bindings", headers=bearer(member)).json()["items"][0]["channel"] == "wechat"
    assert client.get("/api/v1/channels/bindings").json()["items"] == []


def test_the_v1_desktop_bind_code_still_binds_the_owner(env):
    client, app, wechat, _ = env
    code = client.post("/api/v1/wechat/bind-code").json()["code"]
    push(client, bound_token(client), "o_owner", code, msg_id="m1")
    run(client, app)
    assert any("绑定好了" in body["text"]["content"] for body in wechat.custom)
    bindings = client.get("/api/v1/channels/bindings").json()["items"]
    assert [(b["channel"], b["hint"]) for b in bindings] == [("wechat", "····wner")]


def test_unbind_removes_only_my_binding(env):
    client, app, wechat, _ = env
    make_user(app)
    member = login(client, "shidi")
    code = client.post("/api/v1/channels/wechat/bind-code", headers=bearer(member)).json()["code"]
    push(client, bound_token(client), "o_shidi", code, msg_id="m1")
    run(client, app)
    assert client.delete("/api/v1/channels/wechat/binding", headers=bearer(member)).json() == {"unbound": 1}
    push(client, bound_token(client), "o_shidi", "记住：解绑后不该写进任何账号", msg_id="m2")
    run(client, app)
    assert client.get("/api/v1/snapshot", headers=bearer(member)).json().get("memories", []) == []
