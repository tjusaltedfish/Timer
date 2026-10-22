"""WeChat Official Account (接口测试号) channel for the Timer assistant.

Inbound: WeChat pushes XML to /wechat/callback. Every request is signature
checked with the configured Token; only the one bound openid (the user's main
account) is acted on. Messages are deduplicated and stored before the
callback returns, then processed by a background worker, because model
replies take longer than WeChat's passive-reply window.

Outbound: a persistent outbox. Customer-service messages are tried first;
if WeChat reports the 48-hour interaction window has closed, a configured
template message is used instead. A request that may have reached WeChat but
got no answer is recorded as "unknown" and never resent automatically.

Secrets (appsecret, Token) live in <data>/secrets and are never returned in full.
"""
import asyncio
import hashlib
import hmac
import json
import logging
import re
import secrets
import string
import xml.etree.ElementTree as ElementTree
from datetime import datetime, timedelta, timezone

import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .channel_identity import IdentityStore
from .chat_commands import HELP, ChatCommands, split_text
from .domain import DomainError, identifier, parse, stamp

API = "https://api.weixin.qq.com"
CHAT_CONCURRENCY = 4  # 每条通道最多同时处理这么多个账号的消息，避免一个人算 45 秒所有人排队
SCHEMA = """
CREATE TABLE IF NOT EXISTS wechat_inbox (id TEXT PRIMARY KEY, dedup_key TEXT UNIQUE NOT NULL, openid TEXT NOT NULL,
    kind TEXT NOT NULL, content TEXT NOT NULL, received_at TEXT NOT NULL, status TEXT NOT NULL, note TEXT);
CREATE TABLE IF NOT EXISTS wechat_outbox (id TEXT PRIMARY KEY, dedup_key TEXT UNIQUE, openid TEXT NOT NULL,
    text TEXT NOT NULL, not_before TEXT NOT NULL, expires_at TEXT, status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, channel TEXT, last_error TEXT, created_at TEXT NOT NULL, sent_at TEXT);
"""
MAX_BODY = 64 * 1024
SIGNATURE_WINDOW = timedelta(minutes=30)
RETRY_DELAYS = (30, 120, 600, 1800)  # seconds between attempts when WeChat is unreachable
TOKEN_ERRORS = {40001, 40014, 42001}
WINDOW_CLOSED = {45015, 45047}
HINTS = {
    40003: "openid 不属于这个 appID：设置里的 appID / appsecret 要来自你关注的那个测试号",
    48001: "这个 appID 没有发消息的接口权限：请填写「接口测试号」页面上的 appID / appsecret",
    40125: "appsecret 不对：请从测试号页面重新复制",
    40013: "appID 不对：请从测试号页面重新复制",
    43004: "对方没有关注这个测试号",
}
log = logging.getLogger(__name__)


class WeChatConfigIn(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    app_id: str | None = Field(default=None, max_length=32)
    app_secret: str | None = Field(default=None, max_length=64)
    template_id: str | None = Field(default=None, max_length=64)
    regenerate_token: bool = False
    proactive_enabled: bool | None = None

    @field_validator("app_id")
    @classmethod
    def valid_app_id(cls, value):
        if value and not re.fullmatch(r"wx[0-9a-zA-Z]{14,30}", value):
            raise ValueError("appID 形如 wx 开头的一串字母数字，请从测试号页面复制")
        return value

    @field_validator("app_secret", "template_id")
    @classmethod
    def no_spaces(cls, value):
        if value and not re.fullmatch(r"[0-9A-Za-z_\-]+", value):
            raise ValueError("只能包含字母、数字、下划线或短横线")
        return value


class WeChatSettings:
    """wechat.json holds non-secret settings; appsecret and Token are separate files."""

    def __init__(self, directory):
        self.path = directory / "wechat.json"
        self.secret_path = directory / "secrets" / "wechat-secret"
        self.token_path = directory / "secrets" / "wechat-token"

    def load(self):
        try:
            stored = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            stored = {}
        return {"app_id": "", "template_id": "", "bound_openid": "", "bound_at": None, **stored}

    def save(self, conf):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(conf, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(self.path)

    def _read(self, path):
        try:
            return path.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def _write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def secret(self):
        return self._read(self.secret_path)

    def token(self):
        value = self._read(self.token_path)
        if not value:  # WeChat accepts 3–32 letters and digits.
            value = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))
            self._write(self.token_path, value)
        return value

    def update(self, data: WeChatConfigIn):
        conf = self.load()
        if data.app_id is not None:
            if data.app_id != conf["app_id"]:
                conf.update(bound_openid="", bound_at=None)  # openids differ per official account
            conf["app_id"] = data.app_id
        if data.template_id is not None:
            conf["template_id"] = data.template_id
        if data.proactive_enabled is not None:
            conf["proactive_enabled"] = data.proactive_enabled
        self.save(conf)
        if data.app_secret:
            self._write(self.secret_path, data.app_secret)
        if data.regenerate_token:
            self.token_path.unlink(missing_ok=True)
            self.token()

    def configured(self):
        conf = self.load()
        return bool(conf["app_id"] and self.secret())

    def public(self, desktop):
        conf, secret = self.load(), self.secret()
        bound = conf["bound_openid"]
        result = {"proactive_enabled": conf.get("proactive_enabled", True), "configured": bool(conf["app_id"] and secret), "app_id": conf["app_id"],
                  "secret_hint": ("····" + secret[-4:]) if secret else "", "template_id": conf["template_id"],
                  "callback_path": "/wechat/callback", "bound": bool(bound),
                  "bound_hint": ("····" + bound[-4:]) if bound else "", "bound_at": conf["bound_at"]}
        if desktop:
            result["token"] = self.token()  # Needed verbatim on the WeChat configuration page.
        return result


def signature_ok(token, signature, timestamp, nonce, now):
    if not (signature and timestamp and nonce):
        return False
    try:
        sent = datetime.fromtimestamp(int(timestamp), timezone.utc)
    except (ValueError, OverflowError, OSError):
        return False
    if abs(now - sent) > SIGNATURE_WINDOW:
        return False
    expected = hashlib.sha1("".join(sorted([token, timestamp, nonce])).encode()).hexdigest()
    return hmac.compare_digest(expected, signature.lower())


def parse_message(body: bytes):
    if len(body) > MAX_BODY or b"<!DOCTYPE" in body.upper() or b"<!ENTITY" in body.upper():
        raise DomainError("消息格式不受支持", "BAD_MESSAGE", 400)
    try:
        root = ElementTree.fromstring(body)
    except ElementTree.ParseError:
        raise DomainError("消息格式不受支持", "BAD_MESSAGE", 400) from None
    return {child.tag: (child.text or "") for child in root}


class WeChatChannel:
    def __init__(self, store, clock, assistant_service, transport=lambda: None):
        self.store, self.clock, self.assistant = store, clock, assistant_service
        self.transport = transport
        self.settings = WeChatSettings(store.directory)
        self.lock = asyncio.Lock()
        self._token, self._token_expiry = None, None
        self.commands = ChatCommands(store, clock, assistant_service, "wechat")
        self.identities = IdentityStore(store, clock)
        with store.connect() as conn:
            conn.executescript(SCHEMA)
            # A send interrupted mid-request may or may not have reached WeChat.
            conn.execute("UPDATE wechat_outbox SET status='unknown', last_error='后台在发送时中断，是否送达未知' "
                         "WHERE status='sending'")

    # ---- Binding ---------------------------------------------------------
    def new_bind_code(self):
        # Kept on disk (hash only) so a backend restart does not void a code
        # the user is about to send.
        code = "".join(secrets.choice(string.digits) for _ in range(6))
        expires = self.clock() + timedelta(minutes=10)
        conf = self.settings.load()
        conf.update(bind_code_hash=hashlib.sha256(code.encode()).hexdigest(), bind_expires_at=stamp(expires))
        self.settings.save(conf)
        return {"code": code, "expires_at": stamp(expires)}

    def _bind_code_matches(self, conf, content, now):
        expected, expires = conf.get("bind_code_hash"), conf.get("bind_expires_at")
        if not (expected and expires) or parse(expires) <= now:
            return False
        return hmac.compare_digest(hashlib.sha256(content.encode()).hexdigest(), expected)

    def unbind(self):
        conf = self.settings.load()
        conf.update(bound_openid="", bound_at=None)
        self.settings.save(conf)
        return {"bound": False}

    # ---- Inbound ---------------------------------------------------------
    def receive(self, message):
        """Store one pushed message; decide synchronously whether it needs work."""
        now = self.clock()
        openid = message.get("FromUserName", "")
        kind = message.get("MsgType", "")
        content = (message.get("Content") or message.get("Event") or "").strip()[:2000]
        dedup = message.get("MsgId") or f"{openid}:{message.get('CreateTime')}:{kind}:{message.get('Event', '')}"
        conf = self.settings.load()
        with self.store.connect() as conn:
            inserted = conn.execute(
                "INSERT OR IGNORE INTO wechat_inbox VALUES(?,?,?,?,?,?,?,?)",
                (identifier(), dedup, openid, kind, content, stamp(now), "new", None)).rowcount
            if not inserted:
                return False  # WeChat retried a message we already have.
            def mark(status, note=None):
                conn.execute("UPDATE wechat_inbox SET status=?, note=? WHERE dedup_key=?", (status, note, dedup))

            is_code = kind == "text" and re.fullmatch(r"[0-9A-Za-z]{6}", content) is not None
            self._migrate_legacy_binding(conn, openid, conf, now)
            user_id = self.identities.user_of(conn, "wechat", openid)
            if user_id is None:
                if is_code:
                    if self._bind_code_matches(conf, content, now):
                        # The v1 desktop page still writes the code into wechat.json.
                        conf.update(bound_openid=openid, bound_at=stamp(now), bind_code_hash=None, bind_expires_at=None)
                        self.settings.save(conf)
                        self.identities.bind(conn, "wechat", openid, self.store.owner_id, "主账号")
                        mark("done", "bound")
                        self._enqueue(conn, openid, "绑定好了。以后在这里跟我说要安排什么就行。\n\n" + HELP, now)
                        return True
                    user_id, problem = self.identities.redeem(conn, "wechat", content, openid)
                    self.identities.touch(conn, "wechat", openid)
                    if not user_id:
                        mark("done", "bad code")
                        self._enqueue(conn, openid, problem, now)
                        return True
                    mark("done", "bound")
                    self._enqueue(conn, openid, f"绑定好了，以后这个号就是「{self.identities.bindings(conn, user_id)[0]['hint']}」对应的瞬时账号。\n\n" + HELP, now)
                    return True
                if kind == "event" and content == "subscribe":
                    mark("done", "bound")
                    self._enqueue(conn, openid, "欢迎关注。我是瞬时助手：先在瞬时 App 的「账号 · 绑定微信」里生成 6 位绑定码，发给我，就绑定到你的日程。", now)
                    return True
                # Unbound follower: answer once per message with the way to bind.
                mark("done", "unbound")
                self._enqueue(conn, openid, "这个微信号还没绑定瞬时账号。打开瞬时 App →「账号」→「绑定微信」，把 6 位绑定码发给我即可。", now)
                return True
            self.identities.touch(conn, "wechat", openid)
            if kind == "event":
                mark("done", content)
                if content == "subscribe":
                    self._enqueue(conn, openid, "欢迎回来。\n\n" + HELP, now)
                return True
            if kind != "text":
                mark("done", "unsupported")
                self._enqueue(conn, openid, "我暂时只看得懂文字消息。", now)
                return True
            mark("pending")
            return True

    def _migrate_legacy_binding(self, conn, openid, conf, now):
        """v1 kept exactly one bound openid in wechat.json; it belonged to the owner."""
        legacy = conf.get("bound_openid") or ""
        if legacy and openid == legacy and not self.identities.user_of(conn, "wechat", openid):
            self.identities.bind(conn, "wechat", openid, self.store.owner_id, "主账号")


    async def handle(self, text, request_id=None, user_id=None):
        """Reply text for one message from a bound account."""
        return await self._commands(user_id).reply(text, request_id)

    def _commands(self, user_id=None):
        """一条消息一个实例：表情包与临时状态不跨消息串味。"""
        return ChatCommands(self.store, self.clock, self.assistant, "wechat", user_id or self.store.owner_id)

    # ---- Outbound --------------------------------------------------------
    @staticmethod
    def chunks(text, size=600):
        return split_text(text, size)

    def _enqueue(self, conn, openid, text, now, key=None, not_before=None, expires_at=None):
        for index, part in enumerate(self.chunks(text)):
            part_key = f"{key}#{index}" if key else None
            # Later parts sort after earlier ones even when queued in the same instant.
            at = (not_before or now) + timedelta(microseconds=index)
            conn.execute("INSERT OR IGNORE INTO wechat_outbox(id,dedup_key,openid,text,not_before,expires_at,status,created_at) "
                         "VALUES(?,?,?,?,?,?,?,?)",
                         (identifier(), part_key, openid, part, stamp(at),
                          stamp(expires_at) if expires_at else None, "queued", stamp(now)))

    def enqueue(self, text, key=None, not_before=None, expires_at=None):
        """Queue a message to the bound account (reminders, reports, tests)."""
        bound = self.settings.load()["bound_openid"]
        if not bound:
            raise DomainError("还没有绑定微信大号：在电脑端「设置 · 微信助手」生成绑定码", "WECHAT_NOT_BOUND", 409)
        with self.store.connect() as conn:
            self._enqueue(conn, bound, text, self.clock(), key, not_before, expires_at)

    def enqueue_to(self, openid, text, key=None, not_before=None, expires_at=None):
        """Queue a message to one follower (per-user reminders and briefs)."""
        with self.store.connect() as conn:
            self._enqueue(conn, openid, text, self.clock(), key, not_before, expires_at)

    def outbox(self, limit=20):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT id,text,status,channel,attempts,last_error,created_at,sent_at "
                                "FROM wechat_outbox ORDER BY created_at DESC, rowid DESC LIMIT ?", (limit,)).fetchall()
        return [{**dict(r), "text": r["text"][:80]} for r in rows]

    async def _access_token(self, http, refresh=False):
        now = self.clock()
        if not refresh and self._token and self._token_expiry and now < self._token_expiry:
            return self._token
        conf, secret = self.settings.load(), self.settings.secret()
        response = await http.post(f"{API}/cgi-bin/stable_token", json={
            "grant_type": "client_credential", "appid": conf["app_id"], "secret": secret,
            "force_refresh": refresh})
        data = response.json()
        if "access_token" not in data:
            message = str(data.get("errmsg", "")).replace(secret, "****") if secret else str(data.get("errmsg", ""))
            message = HINTS.get(data.get("errcode"), message)
            raise DomainError(f"获取 access_token 失败（{data.get('errcode')}）：{message}", "WECHAT_TOKEN", 502)
        self._token = data["access_token"]
        self._token_expiry = now + timedelta(seconds=max(60, int(data.get("expires_in", 7200)) - 300))
        return self._token

    async def _call(self, http, path, payload):
        """POST with token refresh on token errors. Returns WeChat's JSON."""
        for refresh in (False, True):
            token = await self._access_token(http, refresh)
            data = (await http.post(f"{API}{path}", params={"access_token": token}, json=payload)).json()
            if data.get("errcode") not in TOKEN_ERRORS:
                return data
        return data

    async def deliver(self, http, row):
        now = self.clock()
        with self.store.connect() as conn:
            if not getattr(self, 'notification_valid', lambda _: True)(row['dedup_key']):
                conn.execute("UPDATE wechat_outbox SET status='cancelled' WHERE id=?", (row['id'],))
                return
            if row["expires_at"] and parse(row["expires_at"]) <= now:
                conn.execute("UPDATE wechat_outbox SET status='expired' WHERE id=?", (row["id"],))
                return
            conn.execute("UPDATE wechat_outbox SET status='sending', attempts=attempts+1 WHERE id=?", (row["id"],))
        status, channel, error = "failed", None, None
        try:
            data = await self._call(http, "/cgi-bin/message/custom/send", {
                "touser": row["openid"], "msgtype": "text", "text": {"content": row["text"]}})
            channel = "custom"
            if data.get("errcode") in WINDOW_CLOSED:
                template = self.settings.load()["template_id"]
                if template:
                    channel = "template"
                    data = await self._call(http, "/cgi-bin/message/template/send", {
                        "touser": row["openid"], "template_id": template,
                        "data": {"content": {"value": row["text"][:200]}}})
                else:
                    data = {**data, "errmsg": "超过 48 小时没有互动，且未配置提醒模板"}
            if data.get("errcode", 0) == 0:
                status = "sent"
            else:
                code = data.get("errcode")
                hint = HINTS.get(code)
                error = (f"{code}：{hint}" if hint else f"{code}：{data.get('errmsg', '')}")[:300]
        except httpx.TimeoutException:
            status, error = "unknown", "请求已发出但没有收到微信的答复，是否送达未知，不会自动重发"
        except httpx.TransportError as exc:
            # Never reached WeChat: safe to retry later.
            attempts = row["attempts"] + 1
            if attempts <= len(RETRY_DELAYS):
                with self.store.connect() as conn:
                    conn.execute("UPDATE wechat_outbox SET status='queued', not_before=?, last_error=? WHERE id=?",
                                 (stamp(now + timedelta(seconds=RETRY_DELAYS[attempts - 1])),
                                  f"连不上微信服务器：{type(exc).__name__}", row["id"]))
                return
            error = f"多次连不上微信服务器：{type(exc).__name__}"
        except DomainError as exc:
            error = exc.message
        with self.store.connect() as conn:
            conn.execute("UPDATE wechat_outbox SET status=?, channel=?, last_error=?, sent_at=? WHERE id=?",
                         (status, channel, error, stamp(self.clock()) if status == "sent" else None, row["id"]))

    async def run_once(self):
        """Process waiting inbound messages, then send what is due. Serialised."""
        async with self.lock:
            with self.store.connect() as conn:
                pending = conn.execute("SELECT * FROM wechat_inbox WHERE status IN ('pending','processing') "
                                       "ORDER BY received_at, rowid").fetchall()
            groups, unbound = self._group_pending(pending)
            if unbound:
                with self.store.connect() as conn:
                    for row in unbound:
                        conn.execute("UPDATE wechat_inbox SET status='done', note='unbound' WHERE id=?", (row["id"],))
            if groups:
                limit = asyncio.Semaphore(CHAT_CONCURRENCY)
                await asyncio.gather(*(self._reply_in_order(limit, user_id, rows) for user_id, rows in groups.items()))
            if not self.settings.configured():
                return
            with self.store.connect() as conn:
                due = conn.execute("SELECT * FROM wechat_outbox WHERE status='queued' AND not_before<=? "
                                   "ORDER BY not_before, rowid LIMIT 20", (stamp(self.clock()),)).fetchall()
            if not due:
                return
            async with httpx.AsyncClient(timeout=15, transport=self.transport()) as http:
                for row in due:
                    await self.deliver(http, row)

    def _group_pending(self, pending):
        """按账号分组：未绑定的消息直接给出说明，不占用模型。"""
        groups, unbound = {}, []
        with self.store.connect() as conn:
            for row in pending:
                user_id = self.identities.user_of(conn, "wechat", row["openid"])
                if user_id:
                    groups.setdefault(user_id, []).append(row)
                else:
                    unbound.append(row)
        return groups, unbound

    async def _reply_in_order(self, limit, user_id, rows):
        """同一个账号的消息保持到达顺序；不同账号并行，谁也堵不住谁。"""
        async with limit:
            for row in rows:
                await self._process_row(user_id, row)

    async def _process_row(self, user_id, row):
        with self.store.connect() as conn:
            conn.execute("UPDATE wechat_inbox SET status='processing' WHERE id=?", (row["id"],))
        try:
            reply = await self.handle(row["content"], request_id=row["id"], user_id=user_id)
            status = "done"
        except Exception as error:  # noqa: BLE001 - keep the queue moving, keep the evidence
            log.exception("WeChat message handling failed")
            reply, status = "这条消息处理出错了，已记下，稍后再试一次？", f"failed:{type(error).__name__}"
        with self.store.connect() as conn:
            conn.execute("UPDATE wechat_inbox SET status=? WHERE id=?", (status[:60], row["id"]))
            self._enqueue(conn, row["openid"], reply, self.clock(), key=f"reply:{row['id']}")
