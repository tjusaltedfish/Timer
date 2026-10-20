"""WeChat official-account channel against a simulated WeChat API and model."""
import hashlib
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 Los Angeles
OWNER, STRANGER = "o_owner_openid_1234", "o_stranger_9999"
APP_SECRET = "0123456789abcdef0123456789abcdef"


class FakeWeChat:
    """Minimal api.weixin.qq.com: stable_token, custom send, template send."""

    def __init__(self):
        self.custom, self.template, self.tokens = [], [], 0
        self.custom_replies, self.fail_with = [], None

    def __call__(self, request):
        if self.fail_with:
            raise self.fail_with
        path = request.url.path
        body = json.loads(request.content or b"{}")
        if path == "/cgi-bin/stable_token":
            self.tokens += 1
            assert body["secret"] == APP_SECRET
            return httpx.Response(200, json={"access_token": f"T{self.tokens}", "expires_in": 7200})
        if path == "/cgi-bin/message/custom/send":
            self.custom.append((request.url.params["access_token"], body))
            reply = self.custom_replies.pop(0) if self.custom_replies else {"errcode": 0, "errmsg": "ok"}
            return httpx.Response(200, json=reply)
        if path == "/cgi-bin/message/template/send":
            self.template.append(body)
            return httpx.Response(200, json={"errcode": 0, "errmsg": "ok", "msgid": 1})
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
        yield client, app, wechat, model


def configure(client, **extra):
    response = client.post("/api/v1/wechat/config", json={"app_id": "wx0123456789abcdef", "app_secret": APP_SECRET, **extra})
    assert response.status_code == 200, response.text
    return response.json()


def signed(token, nonce="n1", at=NOW):
    timestamp = str(int(at.timestamp()))
    signature = hashlib.sha1("".join(sorted([token, timestamp, nonce])).encode()).hexdigest()
    return {"signature": signature, "timestamp": timestamp, "nonce": nonce}


def push(client, token, sender, content=None, msg_id="1", kind="text", event=None):
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


def bind(client, app, token):
    code = client.post("/api/v1/wechat/bind-code").json()["code"]
    push(client, token, OWNER, code, msg_id="bind")
    run(client, app)


def test_url_verification_and_signature(env):
    client, app, _, _ = env
    token = configure(client)["token"]
    assert len(token) == 32
    ok = client.get("/wechat/callback", params={**signed(token), "echostr": "hello"})
    assert ok.status_code == 200 and ok.text == "hello"
    bad = client.get("/wechat/callback", params={**signed("wrong"), "echostr": "hello"})
    assert bad.status_code == 403
    stale = client.get("/wechat/callback", params={**signed(token, at=datetime(2026, 10, 18, tzinfo=timezone.utc)), "echostr": "x"})
    assert stale.status_code == 403
    forged = client.post("/wechat/callback", params=signed("wrong"), content=b"<xml></xml>")
    assert forged.status_code == 403


def test_secrets_stay_on_the_computer(env, tmp_path):
    client, _, _, _ = env
    public = configure(client)
    assert APP_SECRET not in json.dumps(public) and public["secret_hint"] == "····cdef"
    assert APP_SECRET not in (tmp_path / "wechat.json").read_text(encoding="utf-8")
    code = client.post("/api/v1/pairing/code").json()["code"]
    phone = {"Authorization": "Bearer " + client.post("/api/v1/pairing/confirm", json={"code": code, "name": "手机"}).json()["token"]}
    seen = client.get("/api/v1/wechat/config", headers=phone).json()
    assert "token" not in seen and seen["configured"] is True
    assert client.post("/api/v1/wechat/config", json={"template_id": "x"}, headers=phone).status_code == 403
    assert client.post("/api/v1/wechat/bind-code", headers=phone).status_code == 403
    assert client.post("/api/v1/wechat/config", json={"app_id": "not-an-app-id"}).status_code == 422


def test_only_the_bound_account_is_answered(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    push(client, token, STRANGER, "今天", msg_id="s1")
    run(client, app)
    assert wechat.custom == []
    push(client, token, STRANGER, "000000", msg_id="s2")  # wrong code
    code = client.post("/api/v1/wechat/bind-code").json()["code"]
    push(client, token, OWNER, code, msg_id="b1")
    run(client, app)
    assert client.get("/api/v1/wechat/config").json()["bound_hint"] == "····1234"
    # Before binding, a wrong code only earns a "code is wrong" note.
    to_stranger = [b["text"]["content"] for _, b in wechat.custom if b["touser"] == STRANGER]
    assert to_stranger == ["这个绑定码不对或已经过期了，请在电脑上的瞬时里重新生成。"]
    assert "绑定好了" in wechat.custom[-1][1]["text"]["content"] and wechat.custom[-1][1]["touser"] == OWNER
    sent = len(wechat.custom)
    push(client, token, STRANGER, code, msg_id="s3")  # replayed code after binding
    push(client, token, STRANGER, "今天", msg_id="s4")
    push(client, token, STRANGER, "123456", msg_id="s5")
    run(client, app)
    assert len(wechat.custom) == sent  # once bound, other accounts get nothing
    assert client.get("/api/v1/wechat/config").json()["bound_hint"] == "····1234"


def test_retried_pushes_are_processed_once(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    for _ in range(3):  # WeChat retries the same MsgId when it gets no quick answer
        push(client, token, OWNER, "今天", msg_id="dup-1")
    push(client, token, OWNER, "今天", msg_id="dup-2")  # the same words sent again are a new message
    run(client, app)
    replies = [b["text"]["content"] for _, b in wechat.custom[1:]]
    assert len(replies) == 2 and all("还没有安排" in r for r in replies)


def test_conversation_drafts_and_confirmation(env):
    client, app, wechat, model = env
    token = configure(client)["token"]
    client.post("/api/v1/assistant/config", json={"base_url": "https://llm.example/v1", "model": "m", "api_key": "sk-test-1234567890",
                                                     "confirm_first": True})
    bind(client, app, token)
    model.replies.append({"reply": "拟办如下。", "drafts": [{"summary": "明早写扫描脚本", "actions": [
        {"type": "schedule_new", "title": "参数扫描脚本", "outcome_criteria": "输出可复现 CSV",
         "start_local": "2026-10-20 10:00", "minutes": 90}]}]})
    push(client, token, OWNER, "明早十点写扫描脚本", msg_id="m1")
    run(client, app)
    reply = wechat.custom[-1][1]["text"]["content"]
    code = reply.split("【拟办 ")[1][:4]
    assert "确认 " + code in reply and "10:00–11:30" in reply
    assert client.get("/api/v1/snapshot").json()["blocks"] == []
    push(client, token, OWNER, f"确认 {code}", msg_id="m2")
    run(client, app)
    assert "已照此办理" in wechat.custom[-1][1]["text"]["content"]
    blocks = client.get("/api/v1/snapshot").json()["blocks"]
    assert len(blocks) == 1 and blocks[0]["start_at"] == "2026-10-20T17:00:00+00:00"
    push(client, token, OWNER, f"确认 {code}", msg_id="m3")
    run(client, app)
    assert "已经处理过" in wechat.custom[-1][1]["text"]["content"] or "没有找到" in wechat.custom[-1][1]["text"]["content"]
    assert len(client.get("/api/v1/snapshot").json()["blocks"]) == 1
    push(client, token, OWNER, "好", msg_id="m4")  # casual reply goes to the assistant, not to a stale draft
    run(client, app)
    assert wechat.custom[-1][1]["text"]["content"] == "好的"


def test_unconfigured_model_still_answers_basics(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    push(client, token, OWNER, "帮我排明天", msg_id="u1")
    run(client, app)
    assert "模型服务还没在电脑上配置好" in wechat.custom[-1][1]["text"]["content"]


def test_window_closed_falls_back_to_template_or_fails_clearly(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    wechat.custom_replies.append({"errcode": 45015, "errmsg": "response out of time limit"})
    client.post("/api/v1/wechat/test")
    run(client, app)
    latest = client.get("/api/v1/wechat/outbox").json()["messages"][0]
    assert latest["status"] == "failed" and "48 小时" in latest["last_error"]
    configure(client, template_id="TPL_reminder")
    wechat.custom_replies.append({"errcode": 45015, "errmsg": "response out of time limit"})
    client.post("/api/v1/wechat/test")
    run(client, app)
    latest = client.get("/api/v1/wechat/outbox").json()["messages"][0]
    assert (latest["status"], latest["channel"]) == ("sent", "template")
    assert wechat.template[-1]["template_id"] == "TPL_reminder" and wechat.template[-1]["touser"] == OWNER


def test_expired_token_is_refreshed_once(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    wechat.custom_replies.append({"errcode": 42001, "errmsg": "access_token expired"})
    client.post("/api/v1/wechat/test")
    run(client, app)
    assert client.get("/api/v1/wechat/outbox").json()["messages"][0]["status"] == "sent"
    assert wechat.custom[-1][0] == f"T{wechat.tokens}" and wechat.tokens == 2


def test_timeout_is_unknown_and_never_resent(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    sent = len(wechat.custom)
    wechat.fail_with = httpx.ReadTimeout("no answer")
    client.post("/api/v1/wechat/test")
    run(client, app)
    run(client, app)
    latest = client.get("/api/v1/wechat/outbox").json()["messages"][0]
    assert latest["status"] == "unknown" and latest["attempts"] == 1
    wechat.fail_with = None
    run(client, app)
    assert len(wechat.custom) == sent


def test_unreachable_wechat_is_retried_later(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    wechat.fail_with = httpx.ConnectError("offline")
    client.post("/api/v1/wechat/test")
    run(client, app)
    latest = client.get("/api/v1/wechat/outbox").json()["messages"][0]
    assert latest["status"] == "queued" and "连不上" in latest["last_error"]


def test_long_replies_are_split_in_order(env):
    client, app, wechat, model = env
    from app.wechat import WeChatChannel
    parts = WeChatChannel.chunks("\n".join(f"第{i}行" + "字" * 80 for i in range(20)))
    assert len(parts) > 1 and all(len(p) <= 600 for p in parts)
    assert "\n".join(parts).count("第") == 20


def test_wrong_account_errors_are_explained(env):
    client, app, wechat, _ = env
    token = configure(client)["token"]
    bind(client, app, token)
    wechat.custom_replies.append({"errcode": 40003, "errmsg": "invalid openid rid: x"})
    client.post("/api/v1/wechat/test")
    run(client, app)
    latest = client.get("/api/v1/wechat/outbox").json()["messages"][0]
    assert latest["status"] == "failed" and "测试号" in latest["last_error"]


def test_bind_code_survives_a_backend_restart_and_bad_codes_get_an_answer(tmp_path, monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    wechat = FakeWeChat()
    first = create_app(tmp_path, clock=lambda: NOW, wechat_transport=httpx.MockTransport(wechat), background=False)
    with TestClient(first) as client:
        client.headers["Authorization"] = "Bearer " + first.state.desktop_token
        token = configure(client)["token"]
        code = client.post("/api/v1/wechat/bind-code").json()["code"]
    restarted = create_app(tmp_path, clock=lambda: NOW, wechat_transport=httpx.MockTransport(wechat), background=False)
    with TestClient(restarted) as client:
        client.headers["Authorization"] = "Bearer " + restarted.state.desktop_token
        wrong = "000000" if code != "000000" else "111111"
        push(client, token, OWNER, wrong, msg_id="r1")
        run(client, restarted)
        assert "不对或已经过期" in wechat.custom[-1][1]["text"]["content"]
        push(client, token, OWNER, code, msg_id="r2")
        run(client, restarted)
        assert "绑定好了" in wechat.custom[-1][1]["text"]["content"]
        assert client.get("/api/v1/wechat/config").json()["bound"] is True
        # Re-binding to another account needs a fresh code; the used one is void.
        push(client, token, STRANGER, code, msg_id="r3")
        run(client, restarted)
        assert all(body["touser"] == OWNER for _, body in wechat.custom)
        fresh = client.post("/api/v1/wechat/bind-code").json()["code"]
        push(client, token, STRANGER, fresh, msg_id="r4")
        run(client, restarted)
        assert client.get("/api/v1/wechat/config").json()["bound_hint"] == "····9999"


def test_assistant_changes_apply_at_once_and_undo_by_reply(env):
    client, app, wechat, model = env
    token = configure(client)["token"]
    client.post("/api/v1/assistant/config", json={"base_url": "https://llm.example/v1", "model": "m", "api_key": "sk-test-1234567890"})
    bind(client, app, token)
    model.replies.append({"reply": "已排明早 10:00 写扫描脚本。", "drafts": [{"summary": "明早写扫描脚本", "actions": [
        {"type": "schedule_new", "title": "参数扫描脚本", "outcome_criteria": "输出可复现 CSV",
         "start_local": "2026-10-20 10:00", "minutes": 90}]}]})
    push(client, token, OWNER, "明早十点写扫描脚本", msg_id="a1")
    run(client, app)
    reply = wechat.custom[-1][1]["text"]["content"]
    assert reply.startswith("已排明早 10:00 写扫描脚本。") and "10:00–11:30" in reply and "确认" not in reply
    assert "撤销 " in reply
    assert [b["status"] for b in client.get("/api/v1/snapshot").json()["blocks"]] == ["scheduled"]
    push(client, token, OWNER, "撤销", msg_id="a2")
    run(client, app)
    assert wechat.custom[-1][1]["text"]["content"] == "已撤销：明早写扫描脚本。"
    assert [b["status"] for b in client.get("/api/v1/snapshot").json()["blocks"]] == ["cancelled"]
    push(client, token, OWNER, "撤销", msg_id="a3")
    run(client, app)
    assert "没有找到可以撤销" in wechat.custom[-1][1]["text"]["content"]
