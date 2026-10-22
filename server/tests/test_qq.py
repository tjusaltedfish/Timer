"""QQ 官方机器人通道：对着假的 QQ OpenAPI 和假网关跑。"""
import asyncio
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant, qq as qq_module
from app.main import create_app
from app.store import digest

NOW = datetime(2026, 10, 21, 16, 0, tzinfo=timezone.utc)
OWNER, STRANGER = "u_owner_openid_5678", "u_stranger_0001"
APP_SECRET = "0123456789abcdef0123456789abcdef"
APP_ID = "102030405"


class FakeQQ:
    """最小的 QQ OpenAPI：取 token、取网关、发私聊消息。"""

    def __init__(self):
        self.sent, self.tokens, self.replies = [], 0, []
        self.uploads = []
        self.fail_with = None
        self.unauthorized_once = False
        self.gateway = "wss://fake.gateway/websocket/"

    def __call__(self, request):
        if self.fail_with:
            raise self.fail_with
        path = request.url.path
        body = json.loads(request.content or b"{}")
        if path == "/app/getAppAccessToken":
            self.tokens += 1
            assert body == {"appId": APP_ID, "clientSecret": APP_SECRET}
            return httpx.Response(200, json={"access_token": f"T{self.tokens}", "expires_in": 7200})
        if path == "/gateway":
            assert request.headers["Authorization"] == f"QQBot T{self.tokens}"
            return httpx.Response(200, json={"url": self.gateway})
        if path.startswith("/img/"):
            if path.endswith("missing.jpg"):
                return httpx.Response(404, json={"error": "gone"})
            if path.endswith("huge.jpg"):
                return httpx.Response(200, content=b"\xff\xd8" + b"0" * (7 * 1024 * 1024),
                                      headers={"content-type": "image/jpeg"})
            if path.endswith("weird.bin"):
                return httpx.Response(200, content=b"PK\x03\x04", headers={"content-type": "application/zip"})
            if path.endswith("octet.jpg"):
                return httpx.Response(200, content=b"\xff\xd8\xff\xe0fake-jpeg-bytes",
                                      headers={"content-type": "application/octet-stream"})
            return httpx.Response(200, content=b"\xff\xd8\xff\xe0fake-jpeg-bytes",
                                  headers={"content-type": "image/jpeg"})
        if path.endswith("/files"):
            self.uploads.append(body)
            return httpx.Response(200, json={"file_info": "fi-1", "ttl": 0})
        if path.startswith("/v2/users/"):
            if self.unauthorized_once:
                self.unauthorized_once = False
                return httpx.Response(401, json={"code": 11244, "message": "AccessToken无效或过期"})
            self.sent.append({"auth": request.headers["Authorization"], "path": path, "body": body})
            reply = self.replies.pop(0) if self.replies else {"id": "mid-1", "timestamp": "1"}
            return httpx.Response(200, json=reply)
        return httpx.Response(404)


class FakeGateway:
    """替代 websockets.connect：按脚本吐帧，没帧就把控制权交回事件循环。"""

    def __init__(self, frames):
        self.frames, self.sent, self.closed = list(frames), [], False

    def __call__(self, url):
        self.url = url
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        self.closed = True
        return False

    async def send(self, data):
        self.sent.append(json.loads(data))

    async def recv(self):
        if self.frames:
            return self.frames.pop(0)
        await asyncio.sleep(3600)  # 让心跳/取消来打断


class FakeModel:
    def __init__(self):
        self.replies, self.requests = [], []

    def __call__(self, request):
        self.requests.append(request)
        body = self.replies.pop(0) if self.replies else {"reply": "好的", "drafts": []}
        content = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})


@pytest.fixture
def fake(tmp_path, monkeypatch):
    """同时能拿到 FakeQQ 和 FakeGateway 的版本。"""
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.setattr(qq_module, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    api, gateway, model = FakeQQ(), FakeGateway([]), FakeModel()
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model),
                     qq_transport=httpx.MockTransport(api), qq_connect=gateway, background=False)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield client, app, api, gateway, model


def notify_key(kind="task", item="1", version="v1"):
    """proactive.py 铸造提醒 key 用的就是这套形状，校验端会逐字重算。"""
    return f"notify:{digest(OWNER)[:12]}:{kind}:{item}:{version}"


def forget_recent_chat(app):
    conf = app.state.qq.settings.load()
    conf.update(last_msg_id="", last_msg_at=None)
    app.state.qq.settings.save(conf)


def configure(client, **extra):
    response = client.post("/api/v1/qq/config", json={"app_id": APP_ID, "app_secret": APP_SECRET, **extra})
    assert response.status_code == 200, response.text
    return response.json()


def configure_model(client):
    """让这一条真的走模型：不然只会回「模型服务还没配置好」。"""
    response = client.post("/api/v1/assistant/config", json={
        "base_url": "https://relay.example/v1/", "model": "deepseek-chat",
        "api_key": "sk-test-key", "confirm_first": True})
    assert response.status_code == 200, response.text


def bind(client, app, openid=OWNER, msg_id="m-bind"):
    code = client.post("/api/v1/qq/bind-code").json()["code"]
    message(app, openid=openid, content=code, msg_id=msg_id)
    return code


def message(app, openid=OWNER, content="今天", msg_id="m1", attachments=None):
    return app.state.qq.receive({"id": msg_id, "content": content,
                                 "author": {"user_openid": openid},
                                 "timestamp": "2026-10-21T16:00:00Z",
                                 "message_type": 0, "attachments": attachments or []})


def run(client, app):
    client.portal.call(app.state.qq.run_once)


def sent_texts(api):
    return [item["body"]["content"] for item in api.sent]


def test_config_never_returns_the_secret(fake):
    client, app, api, gateway, model = fake
    mine = configure(client)
    assert mine["configured"] is True and mine["bound"] is False
    assert mine["app_id"] == APP_ID
    assert mine["secret_hint"] == "····" + APP_SECRET[-4:]
    assert "app_secret" not in json.dumps(mine)
    assert APP_SECRET not in json.dumps(mine)


def test_bind_code_persists_and_only_works_once(fake):
    client, app, api, gateway, model = fake
    configure(client)
    code = bind(client, app)
    run(client, app)
    assert app.state.qq.settings.load()["bound_openid"] == OWNER
    assert "绑定好了" in sent_texts(api)[0]
    # 绑定成功后码要就地抹掉，别把哈希留在盘上当靶子
    conf = app.state.qq.settings.load()
    assert conf.get("bind_code_hash", "") == ""
    assert conf.get("bind_expires_at") is None
    # 同一个码再来一次：已经不是绑定码了，当普通文字处理
    message(app, openid=STRANGER, content=code, msg_id="m-again")
    run(client, app)
    assert app.state.qq.settings.load()["bound_openid"] == OWNER


def test_strangers_are_ignored_silently(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    assert message(app, openid=STRANGER, content="帮我加个会", msg_id="m-stranger") is False
    run(client, app)
    assert api.sent == []


def test_unbound_stranger_gets_no_reply_at_all(fake):
    client, app, api, gateway, model = fake
    configure(client)
    assert message(app, openid=STRANGER, content="你好", msg_id="m-hi") is False
    run(client, app)
    assert api.sent == []


def test_duplicate_push_is_answered_once(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    assert message(app, msg_id="m-dup") is True
    assert message(app, msg_id="m-dup") is False
    run(client, app)
    assert len(sent_texts(api)) == 1


def test_attachments_we_cannot_read_get_a_plain_hint(fake):
    """语音/视频/文件还没有解析能力；能读的只有文字和图片。"""
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    assert message(app, content="", msg_id="m-voice",
                   attachments=[{"content_type": "voice", "url": "https://cdn.example/v.silk"}]) is True
    run(client, app)
    assert "还看不了" in sent_texts(api)[0]


def picture_message(app, url="https://cdn.example/img/1.jpg", mime="image/jpeg", msg_id="m-img", content=""):
    return message(app, content=content, msg_id=msg_id,
                   attachments=[{"content_type": mime, "url": url, "filename": "1.jpg", "size": 1024}])


def test_a_picture_is_shown_to_the_model(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    model.replies = [{"reply": "图里是明早九点的课，我给你排上？", "drafts": []}]
    assert picture_message(app) is True
    run(client, app)
    body = json.loads(model.requests[0].content)
    parts = body["messages"][-1]["content"]
    assert body["messages"][-1]["role"] == "user"
    assert parts[0] == {"type": "text", "text": "看看这张图。"}
    assert parts[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert "图里是明早九点的课" in sent_texts(api)[0]
    with app.state.store.connect() as conn:
        row = conn.execute("SELECT kind,status,media_url FROM qq_inbox ORDER BY rowid DESC LIMIT 1").fetchone()
    assert row["kind"] == "image" and row["status"] == "done"
    assert row["media_url"] == "https://cdn.example/img/1.jpg"
    with app.state.store.connect() as conn:
        stored = conn.execute("SELECT role,text FROM assistant_messages ORDER BY rowid DESC LIMIT 2").fetchall()
    assert stored[-1]["text"] == "[图片]"


def test_an_octet_stream_download_still_counts_as_a_picture(fake):
    """腾讯的 CDN 有时把图片报成 application/octet-stream，这时信 QQ 给的 content_type。"""
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    model.replies = [{"reply": "看到了，蓝头发那位。", "drafts": []}]
    assert picture_message(app, url="https://cdn.example/img/octet.jpg", msg_id="m-octet") is True
    run(client, app)
    assert model.requests
    parts = json.loads(model.requests[0].content)["messages"][-1]["content"]
    assert parts[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert "蓝头发那位" in sent_texts(api)[-1]
    with app.state.store.connect() as conn:
        row = conn.execute("SELECT kind,status FROM qq_inbox ORDER BY rowid DESC LIMIT 1").fetchone()
    assert row["kind"] == "image" and row["status"] == "done"


def test_the_caption_goes_with_the_picture(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    model.replies = [{"reply": "课表收到了，先记着。", "drafts": []}]
    picture_message(app, content="这是我明天的课表", msg_id="m-img2")
    run(client, app)
    parts = json.loads(model.requests[0].content)["messages"][-1]["content"]
    assert parts[0]["text"] == "这是我明天的课表"


def test_an_oversized_picture_is_refused_without_calling_the_model(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    picture_message(app, url="https://cdn.example/img/huge.jpg", msg_id="m-big")
    run(client, app)
    assert model.requests == []
    assert "太大" in sent_texts(api)[0]


def test_a_picture_that_cannot_be_fetched_gets_a_plain_answer(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    picture_message(app, url="https://cdn.example/img/missing.jpg", msg_id="m-gone")
    run(client, app)
    assert model.requests == []
    assert "没下载下来" in sent_texts(api)[0]


def test_a_file_that_is_not_really_a_picture_is_refused(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    configure_model(client)
    api.sent.clear()
    picture_message(app, url="https://cdn.example/img/weird.bin", mime="image/jpeg", msg_id="m-zip")
    run(client, app)
    assert model.requests == []
    assert "打不开" in sent_texts(api)[0]


def test_reply_is_passive_and_uses_the_incoming_message_id(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    message(app, content="今天", msg_id="m-today")
    run(client, app)
    body = api.sent[0]["body"]
    assert body["msg_id"] == "m-today" and body["msg_seq"] == 1
    assert body["msg_type"] == 0 and body["content"]


def test_long_reply_is_split_in_order(fake, monkeypatch):
    client, app, api, gateway, model = fake
    monkeypatch.setattr(qq_module, "SEND_LIMIT", 12)
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    message(app, content="帮助", msg_id="m-long")
    run(client, app)
    seqs = [item["body"].get("msg_seq") for item in api.sent]
    assert seqs == list(range(1, len(seqs) + 1)) and len(seqs) >= 2
    assert all(item["body"]["msg_id"] == "m-long" for item in api.sent)
    assert "".join(sent_texts(api)).replace("\n", "") == qq_module.HELP.replace("\n", "")


def test_reminder_without_recent_chat_goes_out_as_active(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    app.state.qq.notification_valid = lambda key: True  # 这条测投递，提醒 key 的校验另有集成测试
    forget_recent_chat(app)
    app.state.qq.enqueue("该睡觉了", key=notify_key())
    run(client, app)
    assert "msg_id" not in api.sent[0]["body"]


def test_reminder_borrows_the_recent_passive_window(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    message(app, content="今天", msg_id="m-recent")
    run(client, app)
    api.sent.clear()
    app.state.qq.notification_valid = lambda key: True
    app.state.qq.enqueue("该睡觉了", key=notify_key())
    run(client, app)
    body = api.sent[0]["body"]
    assert body["msg_id"] == "m-recent" and body["msg_seq"] == 100


def test_expired_passive_window_falls_back_to_active(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    message(app, content="今天", msg_id="m-fallback")
    api.replies[:] = [{"code": 40034128, "message": "被动消息过期"}]
    run(client, app)
    first, second = api.sent[0]["body"], api.sent[1]["body"]
    assert first["msg_id"] == "m-fallback"
    assert "msg_id" not in second
    assert "过期" not in json.dumps(second)


def test_duplicate_msg_seq_is_retried_with_a_new_one(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    message(app, content="今天", msg_id="m-dupseq")
    api.replies[:] = [{"code": 40054005, "message": "消息被去重"}]
    run(client, app)
    assert [item["body"]["msg_seq"] for item in api.sent] == [1, 2]


def test_token_is_fetched_once_then_reused(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-token")
    run(client, app)
    assert api.tokens == 1
    assert api.sent[-1]["auth"] == "QQBot T1"


def test_unauthorized_refetches_the_token_once(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-401")
    api.unauthorized_once = True
    run(client, app)
    assert api.tokens == 2
    assert api.sent[-1]["auth"] == "QQBot T2"


def test_timeout_is_unknown_and_never_resent(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-slow")
    api.fail_with = httpx.ReadTimeout("too slow")
    run(client, app)
    row = app.state.qq.outbox()[0]
    assert row["status"] == "unknown"
    api.fail_with = None
    api.sent.clear()
    run(client, app)
    assert api.sent == []


def test_unreachable_server_is_requeued(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-offline")
    api.fail_with = httpx.ConnectError("no route")
    run(client, app)
    assert app.state.qq.outbox()[0]["status"] == "queued"
    api.fail_with = None
    api.sent.clear()
    run(client, app)
    assert len(api.sent) == 1


def test_rate_limit_is_requeued_not_failed(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-rate")
    api.replies[:] = [{"code": 40034100, "message": "频率限制"}]
    run(client, app)
    row = app.state.qq.outbox()[0]
    assert row["status"] == "queued" and "40034100" in (row["last_error"] or "")


def test_business_error_is_reported_with_a_hint(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    message(app, content="今天", msg_id="m-blocked")
    api.replies[:] = [{"code": 40054013, "message": "主动消息被关闭"}, {"code": 40054013}]
    run(client, app)
    row = app.state.qq.outbox()[0]
    assert row["status"] == "failed" and "允许主动发送" in row["last_error"]


def test_stale_notification_is_cancelled_before_sending(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    app.state.qq.enqueue("早就该取消的提醒", key="notify:deadbeefcafe:task:9:v1")
    app.state.qq.notification_valid = lambda key: False
    run(client, app)
    assert api.sent == [] and app.state.qq.outbox()[0]["status"] == "cancelled"


def test_expired_message_is_never_sent(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    app.state.qq.notification_valid = lambda key: True
    app.state.qq.enqueue("过期的提醒", key=notify_key(item="2"),
                         expires_at=NOW - timedelta(minutes=1))
    run(client, app)
    assert api.sent == [] and app.state.qq.outbox()[0]["status"] == "expired"


def test_reminders_follow_the_bound_channel(fake):
    client, app, api, gateway, model = fake
    configure(client)
    assert app.state.proactive.channel.active is app.state.wechat
    bind(client, app)
    assert app.state.proactive.channel.active is app.state.qq


def test_websocket_identifies_with_the_c2c_intent(fake):
    client, app, api, gateway, model = fake
    configure(client)
    gateway.frames[:] = [json.dumps({"op": 10, "d": {"heartbeat_interval": 45000}})]

    def handshake():
        return asyncio.wait_for(app.state.qq._session(), timeout=0.2)

    with pytest.raises(asyncio.TimeoutError):
        client.portal.call(handshake)
    identify = [frame for frame in gateway.sent if frame["op"] == 2][0]
    assert identify["d"]["intents"] == 33554432
    assert identify["d"]["token"] == "QQBot T1"
    assert gateway.url == api.gateway


def test_websocket_heartbeat_uses_the_latest_sequence(fake):
    client, app, api, gateway, model = fake
    configure(client)
    gateway.frames[:] = [
        json.dumps({"op": 10, "d": {"heartbeat_interval": 50}}),
        json.dumps({"op": 0, "s": 7, "t": "READY", "d": {"session_id": "s1"}}),
    ]

    def handshake():
        return asyncio.wait_for(app.state.qq._session(), timeout=0.3)

    with pytest.raises(asyncio.TimeoutError):
        client.portal.call(handshake)
    beat = [frame for frame in gateway.sent if frame["op"] == 1][-1]
    assert beat["d"] == 7


def test_websocket_message_gets_a_reply(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    gateway.frames[:] = [
        json.dumps({"op": 10, "d": {"heartbeat_interval": 45000}}),
        json.dumps({"op": 0, "s": 1, "t": "READY", "d": {"session_id": "s1"}}),
        json.dumps({"op": 0, "s": 2, "t": "C2C_MESSAGE_CREATE",
                    "d": {"id": "m-ws", "content": "今天", "author": {"user_openid": OWNER},
                          "timestamp": "2026-10-21T16:00:00Z"}}),
    ]

    def handshake():
        return asyncio.wait_for(app.state.qq._session(), timeout=0.4)

    with pytest.raises(asyncio.TimeoutError):
        client.portal.call(handshake)
    client.portal.call(asyncio.sleep, 0.05)
    assert sent_texts(api) and api.sent[0]["body"]["msg_id"] == "m-ws"
    assert app.state.qq.connected is True


def test_reconnect_frame_ends_the_session(fake):
    client, app, api, gateway, model = fake
    configure(client)
    gateway.frames[:] = [
        json.dumps({"op": 10, "d": {"heartbeat_interval": 45000}}),
        json.dumps({"op": 0, "s": 1, "t": "READY", "d": {"session_id": "s1"}}),
        json.dumps({"op": 7}),
    ]
    assert client.portal.call(app.state.qq._session) is True


def test_test_route_queues_through_qq(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    assert client.post("/api/v1/qq/test").json() == {"queued": True}
    run(client, app)
    assert "QQ" in sent_texts(api)[0]


def test_unbind_stops_the_channel(fake):
    client, app, api, gateway, model = fake
    configure(client)
    bind(client, app)
    assert client.post("/api/v1/qq/unbind").json() == {"bound": False}
    assert client.get("/api/v1/qq/config").json()["bound"] is False
    assert app.state.proactive.channel.active is app.state.wechat


def test_meme_request_sends_text_then_image(fake, monkeypatch):
    """模型说想发表情包：先一句话，再传图，图片走 msg_type=7。"""
    import base64
    monkeypatch.setattr(qq_module.memes, "pick", lambda category, rng=None, avoid=(): "happy/1.jpg")
    client, app, api, gateway, model = fake
    configure(client)
    configure_model(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    model.replies.append({"reply": "笑死，这段你居然做完了", "drafts": [], "meme": "happy"})
    message(app, content="在吗", msg_id="m-meme")
    run(client, app)
    assert [item["body"]["msg_type"] for item in api.sent] == [0, 7]
    assert api.sent[1]["body"]["media"]["file_info"] == "fi-1"
    assert api.sent[1]["body"]["msg_id"] == "m-meme"
    upload = api.uploads[0]
    assert upload["file_type"] == 1 and upload["srv_send_msg"] is False
    assert base64.b64decode(upload["file_data"])[:2] == b"\xff\xd8"


def test_meme_is_dropped_when_the_reply_reports_a_failure(fake):
    """回复里带报错/没办成时不许配图：图和文字对不上比不发还难看。"""
    client, app, api, gateway, model = fake
    configure(client)
    configure_model(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    model.replies.append({"reply": "这段我三下五除二搞定了", "meme": "like",
                          "drafts": [{"summary": "改期", "actions": [
                              {"type": "move_block", "block": "b9", "start_local": "2026-10-20 10:00"}]}]})
    message(app, content="算法题挪一下", msg_id="m-meme-fail")
    run(client, app)
    assert [item["body"]["msg_type"] for item in api.sent] == [0]
    assert api.uploads == []


def test_no_meme_art_sends_text_only(fake, monkeypatch, tmp_path):
    """素材没下载全时整段静默，聊天不能因为缺图而失败。"""
    client, app, api, gateway, model = fake
    monkeypatch.setattr(qq_module.memes, "ROOT", tmp_path / "no-art")
    configure(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    model.replies.append({"reply": "嗯", "drafts": [], "meme": "happy"})
    message(app, content="在吗", msg_id="m-noart")
    run(client, app)
    assert [item["body"]["msg_type"] for item in api.sent] == [0]
    assert api.uploads == []


def test_unknown_meme_category_is_ignored(fake):
    client, app, api, gateway, model = fake
    configure(client)
    configure_model(client)
    bind(client, app)
    run(client, app)
    api.sent.clear()
    model.replies.append({"reply": "嗯", "drafts": [], "meme": "狂喜"})
    message(app, content="在吗", msg_id="m-bad")
    run(client, app)
    assert [item["body"]["msg_type"] for item in api.sent] == [0]


def test_a_chat_message_in_qq_can_actually_change_the_schedule(fake):
    """用户在 QQ 里让排一件事：从收消息到写进日程要真能走完（防止「光收到不干活」）。"""
    client, app, api, gateway, model = fake
    configure(client)
    configure_model(client)
    client.post("/api/v1/assistant/config", json={"confirm_first": False})
    bind(client, app)
    run(client, app)
    api.sent.clear()
    model.replies.append({"reply": "排上了。", "drafts": [{"summary": "学算法", "actions": [
        {"type": "schedule_new", "title": "学习算法", "outcome_criteria": "跑通两个例子",
         "start_local": "2026-10-22 10:00", "minutes": 120}]}]})
    message(app, content="明早十点学两小时算法", msg_id="m-sched")
    run(client, app)
    blocks = client.get("/api/v1/snapshot").json()["blocks"]
    assert [block["title"] for block in blocks] == ["学习算法"]
    answers = sent_texts(api)
    assert answers and ("已排" in answers[0] or "排上" in answers[0])
    assert answers[0] != "收到。"
