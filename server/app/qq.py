"""QQ 官方机器人通道：WebSocket 收消息，OpenAPI 发消息。

相对 wechat.py 的取舍：
- QQ 的 WebSocket 是**出站连接**，所以没有公网回调、没有签名校验与 30 分钟窗口；
- 保留同一套投递状态机（queued/sending/sent/failed/unknown/expired/cancelled）、
  幂等 dedup_key、not_before 排序、expires_at 过期、超时记 unknown 不重发；
- 显式针对 C2C 私聊写：intents 只用 GROUP_AND_C2C_EVENT，只处理不带 group_openid 的事件。

指令解释完全交给 chat_commands.ChatCommands —— 微信和 QQ 对同一句话给出同样的回复。
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import re
import secrets
import string
from datetime import timedelta
from urllib.parse import quote

import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import memes
from .chat_commands import HELP, ChatCommands, split_text
from .domain import DomainError, identifier, parse, stamp

log = logging.getLogger(__name__)

API = "https://api.bot.qq.com"
TOKEN_URL = "https://bots.qq.com/app/getAppAccessToken"
INTENTS = 1 << 25  # GROUP_AND_C2C_EVENT：C2C 私聊消息
OP_DISPATCH, OP_HEARTBEAT, OP_IDENTIFY = 0, 1, 2
OP_RECONNECT, OP_INVALID_SESSION, OP_HELLO, OP_HEARTBEAT_ACK = 7, 9, 10, 11
SEND_LIMIT = 1000  # 一段文字的上限，超了就分条发（QQ 单条约 2000 字）
PASSIVE_WINDOW = timedelta(minutes=45)  # 被动回复窗口按 60 分钟算，这里留出余量
RETRY_DELAYS = (30, 120, 600, 1800)
# 被动凭证失效 / 越权：清掉 msg_id 改走主动消息
PASSIVE_LOST = {40034128, 40034005, 304027, 40034103, 40034024}
# 频次或权限：延后重试，不要立刻失败
RATE_LIMITED = {40034100, 40034105, 1100100, 1100101, 1100103}
DUPLICATE = {40054005}  # msg_id + msg_seq 已用过：换一个序号重发
ERR_HINTS = {
    100001: "获取 token 太频繁，等一会再试",
    100007: "AppID 无效或已被封禁，去 QQ 开放平台核对",
    100016: "AppID 或 AppSecret 不对，去 QQ 开放平台复制",
    10004: "机器人不存在：AppID 要来自已创建好的机器人",
    11241: "缺少 access_token",
    11243: "access_token 失效，已尝试重新获取",
    11253: "这个机器人没有调该接口的权限",
    11265: "机器人已被封禁",
    40054013: "你在 QQ 里关掉了「允许主动发送的消息」，这条只能在 60 分钟内回你的时候发出",
    40054004: "需要先在 QQ 里添加这个机器人为好友",
    40034006: "内容触发了 QQ 的审核规则",
    40054007: "消息太长",
    40054018: "消息太长",
    304018: "机器人没和 QQ 网关连上：等后台重连后再试",
}
SCHEMA = """
CREATE TABLE IF NOT EXISTS qq_inbox (id TEXT PRIMARY KEY, dedup_key TEXT UNIQUE NOT NULL, openid TEXT NOT NULL,
    kind TEXT NOT NULL, content TEXT NOT NULL, received_at TEXT NOT NULL, msg_id TEXT, status TEXT NOT NULL, note TEXT);
CREATE TABLE IF NOT EXISTS qq_outbox (id TEXT PRIMARY KEY, dedup_key TEXT UNIQUE, openid TEXT NOT NULL,
    text TEXT NOT NULL, not_before TEXT NOT NULL, expires_at TEXT, status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, channel TEXT, last_error TEXT, created_at TEXT NOT NULL, sent_at TEXT,
    msg_id TEXT, msg_at TEXT, msg_seq INTEGER NOT NULL DEFAULT 1, kind TEXT NOT NULL DEFAULT 'text');
"""


def _websocket_connect(url):
    """延迟导入：只有真正跑长连接时才需要 websockets（uvicorn[standard] 已带上）。"""
    import websockets

    return websockets.connect(url, open_timeout=15, close_timeout=5, ping_interval=None)


class QQConfigIn(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    app_id: str | None = Field(default=None, max_length=32)
    app_secret: str | None = Field(default=None, max_length=128)
    proactive_enabled: bool | None = None

    @field_validator("app_id")
    @classmethod
    def valid_app_id(cls, value):
        if value and not re.fullmatch(r"\d{5,25}", value):
            raise ValueError("AppID 是 QQ 开放平台上那串数字，不是 AppSecret")
        return value

    @field_validator("app_secret")
    @classmethod
    def no_spaces(cls, value):
        if value and not re.fullmatch(r"[0-9A-Za-z_\-]+", value):
            raise ValueError("AppSecret 只能包含字母、数字、下划线或短横线")
        return value


class QQSettings:
    """qq.json 存非机密配置；AppSecret 单独一个文件，不进 qq.json。"""

    def __init__(self, directory):
        self.path = directory / "qq.json"
        self.secret_path = directory / "secrets" / "qq-secret"

    def load(self):
        try:
            stored = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            stored = {}
        return {"app_id": "", "bound_openid": "", "bound_at": None,
                "last_msg_id": "", "last_msg_at": None, **stored}

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

    def update(self, data: QQConfigIn):
        conf = self.load()
        if data.app_id is not None:
            if data.app_id != conf["app_id"]:
                # user_openid 是 per-机器人 的，换了机器人旧绑定就失效
                conf.update(bound_openid="", bound_at=None, last_msg_id="", last_msg_at=None)
            conf["app_id"] = data.app_id
        if data.proactive_enabled is not None:
            conf["proactive_enabled"] = data.proactive_enabled
        self.save(conf)
        if data.app_secret:
            self._write(self.secret_path, data.app_secret)

    def configured(self):
        return bool(self.load()["app_id"] and self.secret())

    def public(self, desktop):
        conf, secret = self.load(), self.secret()
        bound = conf["bound_openid"]
        result = {
            "proactive_enabled": conf.get("proactive_enabled", True),
            "configured": bool(conf["app_id"] and secret),
            "app_id": conf["app_id"],
            "secret_hint": ("····" + secret[-4:]) if secret else "",
            "bound": bool(bound),
            "bound_hint": ("····" + bound[-4:]) if bound else "",
            "bound_at": conf["bound_at"],
            "bind_hint": "" if bound else "在 QQ 里搜机器人名字，或回开放平台页面点「扫码聊天」找到它，再把 6 位绑定码发给它",
        }
        return result


class QQChannel:
    def __init__(self, store, clock, assistant_service, transport=lambda: None, connect=None):
        self.store, self.clock, self.assistant = store, clock, assistant_service
        self.transport = transport  # httpx transport 工厂，测试用 MockTransport
        self.connect = connect or _websocket_connect  # websockets.connect 的替身，测试用假网关
        self.settings = QQSettings(store.directory)
        self.commands = ChatCommands(store, clock, assistant_service, "qq")
        self.lock = asyncio.Lock()
        self.connected = False
        self._token, self._token_expiry = None, None
        self._tasks = set()
        with store.connect() as conn:
            conn.executescript(SCHEMA)
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(qq_outbox)")}
            if "kind" not in columns:  # 表情包是后加的：老库补一列，不动已有行
                conn.execute("ALTER TABLE qq_outbox ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'")
            # 发送中途断电：QQ 那边可能已经收到了，不能自动重发
            conn.execute("UPDATE qq_outbox SET status='unknown', last_error='后台在发送时中断，是否送达未知' "
                         "WHERE status='sending'")

    # ---- Binding ---------------------------------------------------------
    def new_bind_code(self):
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
        conf.update(bound_openid="", bound_at=None, last_msg_id="", last_msg_at=None)
        self.settings.save(conf)
        return {"bound": False}

    # ---- Inbound ---------------------------------------------------------
    def receive(self, event):
        """Handle one C2C_MESSAGE_CREATE payload. Returns True when a reply is owed."""
        now = self.clock()
        msg_id = str(event.get("id") or "")
        author = event.get("author") or {}
        openid = author.get("user_openid") or author.get("id") or ""
        if not (msg_id and openid):
            return False
        content = str(event.get("content") or "").strip()[:2000]
        kind = "text" if content else ("media" if event.get("attachments") else "empty")
        conf = self.settings.load()
        with self.store.connect() as conn:
            inserted = conn.execute(
                "INSERT OR IGNORE INTO qq_inbox(id,dedup_key,openid,kind,content,received_at,msg_id,status) "
                "VALUES(?,?,?,?,?,?,?,'new')",
                (identifier(), msg_id, openid, kind, content, stamp(now), msg_id)).rowcount
            if not inserted:
                return False  # QQ 重推同一条消息

            def mark(status, note=None):
                conn.execute("UPDATE qq_inbox SET status=?, note=? WHERE dedup_key=?", (status, note, msg_id))

            bound = conf["bound_openid"]
            if bound and openid != bound:
                mark("ignored", "other account")
                return False  # 不让陌生人消耗额度
            if not bound:
                if re.fullmatch(r"\d{6}", content) and self._bind_code_matches(conf, content, now):
                    conf.update(bound_openid=openid, bound_at=stamp(now),
                                last_msg_id=msg_id, last_msg_at=stamp(now),
                                bind_code_hash="", bind_expires_at=None)
                    self.settings.save(conf)
                    self._enqueue(conn, openid, "绑定好了，之后在 QQ 里直接说想安排什么就行。\n\n" + HELP,
                                  now, key=f"bind:{msg_id}", msg_id=msg_id, msg_at=now)
                    mark("done")
                    return True
                if re.fullmatch(r"\d{6}", content):
                    self._enqueue(conn, openid, "这个绑定码不对，或者已经过期了。在电脑端「设置 · QQ 助手」重新生成一个。",
                                  now, key=f"badcode:{msg_id}", msg_id=msg_id, msg_at=now)
                    mark("done")
                    return True
                mark("ignored", "not bound")
                return False

            conf.update(last_msg_id=msg_id, last_msg_at=stamp(now))
            self.settings.save(conf)
            if kind == "text":
                mark("pending")
                return True
            self._enqueue(conn, openid, "我暂时只看得懂文字消息。", now,
                          key=f"media:{msg_id}", msg_id=msg_id, msg_at=now)
            mark("done")
            return True

    # ---- Outbound --------------------------------------------------------
    def _enqueue(self, conn, openid, text, now, key=None, not_before=None, expires_at=None,
                 msg_id=None, msg_at=None):
        """Queue one logical message; long text is split and kept in order."""
        if not msg_id:
            conf = self.settings.load()
            fresh = conf.get("last_msg_at")
            # 60 分钟被动窗口是主动提醒唯一免费的活路：用户刚说过话就先借他的 msg_id
            if conf.get("last_msg_id") and fresh and now - parse(fresh) <= PASSIVE_WINDOW:
                msg_id, msg_at = conf["last_msg_id"], parse(fresh)
        # 提醒/周报的序号从 100 起，和「回复某条消息」的 1,2,3… 分开，避免撞 msg_seq
        base = 100 if key and key.split(":")[0] in ("notify", "weekly", "test") else 1
        for index, part in enumerate(split_text(text, SEND_LIMIT)):
            part_key = f"{key}#{index}" if key else None
            # 同一刻入队的各段靠 rowid 定序（查询都按 not_before, rowid 排），
            # 不用微秒偏移——否则一次长回复要被拆到好几轮才发完。
            at = not_before or now
            conn.execute(
                "INSERT OR IGNORE INTO qq_outbox(id,dedup_key,openid,text,not_before,expires_at,status,"
                "created_at,msg_id,msg_at,msg_seq) VALUES(?,?,?,?,?,?,'queued',?,?,?,?)",
                (identifier(), part_key, openid, part, stamp(at),
                 stamp(expires_at) if expires_at else None, stamp(now), msg_id,
                 stamp(msg_at) if msg_at else None, base + index))

    def _enqueue_meme(self, conn, openid, name, now, key=None, msg_id=None, msg_at=None):
        """Queue one image row. 表情包不分片，也不受长文本限制。"""
        if not msg_id:
            conf = self.settings.load()
            fresh = conf.get("last_msg_at")
            if conf.get("last_msg_id") and fresh and now - parse(fresh) <= PASSIVE_WINDOW:
                msg_id, msg_at = conf["last_msg_id"], parse(fresh)
        seq = 1 if not key or key.split(":")[0] not in ("notify", "weekly", "test") else 100
        conn.execute(
            "INSERT OR IGNORE INTO qq_outbox(id,dedup_key,openid,text,not_before,expires_at,status,"
            "created_at,msg_id,msg_at,msg_seq,kind) VALUES(?,?,?,?,?,NULL,'queued',?,?,?,?,'image')",
            (identifier(), f"{key}#meme" if key else None, openid, name, stamp(now), stamp(now),
             msg_id, stamp(msg_at) if msg_at else None, seq))

    def enqueue_meme(self, category, key=None):
        """发一张表情包给绑定的账号；没有素材就安静地跳过。"""
        name = memes.pick(category)
        if name is None:
            return None
        bound = self.settings.load()["bound_openid"]
        if not bound:
            return None
        with self.store.connect() as conn:
            self._enqueue_meme(conn, bound, name, self.clock(), key)
        return name

    def enqueue(self, text, key=None, not_before=None, expires_at=None):
        """Queue a message to the bound account (reminders, reports, tests)."""
        bound = self.settings.load()["bound_openid"]
        if not bound:
            raise DomainError("还没有绑定 QQ：在电脑端「设置 · QQ 助手」生成绑定码，然后在 QQ 里发给机器人",
                              "QQ_NOT_BOUND", 409)
        with self.store.connect() as conn:
            self._enqueue(conn, bound, text, self.clock(), key, not_before, expires_at)

    def outbox(self, limit=20):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT id,text,status,channel,attempts,last_error,created_at,sent_at "
                                "FROM qq_outbox ORDER BY created_at DESC, rowid DESC LIMIT ?", (limit,)).fetchall()
        return [{**dict(r), "text": r["text"][:80]} for r in rows]

    def status(self):
        return {"configured": self.settings.configured(), "bound": bool(self.settings.load()["bound_openid"]),
                "connected": self.connected}

    # ---- QQ OpenAPI ------------------------------------------------------
    async def _access_token(self, http, refresh=False):
        now = self.clock()
        if not refresh and self._token and self._token_expiry and now < self._token_expiry:
            return self._token
        conf, secret = self.settings.load(), self.settings.secret()
        response = await http.post(TOKEN_URL, json={"appId": conf["app_id"], "clientSecret": secret})
        try:
            data = response.json()
        except ValueError:
            data = {}
        if "access_token" not in data:
            code = data.get("code")
            hint = ERR_HINTS.get(code) or str(data.get("message") or "响应里没有 access_token")
            raise DomainError(f"获取 QQ access_token 失败（{code}）：{hint}", "QQ_TOKEN", 502)
        self._token = data["access_token"]
        self._token_expiry = now + timedelta(seconds=max(60, int(data.get("expires_in") or 7200) - 60))
        return self._token

    async def _gateway(self, http, token):
        response = await http.get(f"{API}/gateway", headers={"Authorization": f"QQBot {token}"})
        try:
            data = response.json()
        except ValueError:
            data = {}
        url = data.get("url")
        if not url:
            raise DomainError(f"拿不到 QQ 网关地址（{response.status_code}）：{data.get('message') or data}",
                              "QQ_GATEWAY", 502)
        return url

    async def _call(self, http, method, path, payload):
        """Call the OpenAPI; a 401 means the token died, so fetch a new one once."""
        response = None
        for refresh in (False, True):
            token = await self._access_token(http, refresh)
            response = await http.request(method, f"{API}{path}", json=payload,
                                          headers={"Authorization": f"QQBot {token}"})
            if response.status_code != 401:
                break
        try:
            return response.status_code, response.json()
        except (ValueError, AttributeError):
            return response.status_code if response is not None else 0, {}

    async def _upload(self, http, openid, name):
        """把一张本地表情包传成 file_info；QQ 不接受图片 URL。"""
        raw = memes.read(name)
        if raw is None:
            return None
        code, data = await self._call(http, "POST", f"/v2/users/{quote(openid)}/files", {
            "file_type": 1, "file_data": base64.b64encode(raw).decode(),
            "srv_send_msg": False, "ttl": 0})
        return data.get("file_info")

    async def deliver(self, http, row):
        now = self.clock()
        with self.store.connect() as conn:
            valid = getattr(self, "notification_valid", lambda _: True)
            if not valid(row["dedup_key"]):
                conn.execute("UPDATE qq_outbox SET status='cancelled' WHERE id=?", (row["id"],))
                return
            if row["expires_at"] and parse(row["expires_at"]) <= now:
                conn.execute("UPDATE qq_outbox SET status='expired' WHERE id=?", (row["id"],))
                return
            conn.execute("UPDATE qq_outbox SET status='sending', attempts=attempts+1 WHERE id=?", (row["id"],))
        msg_id, seq = row["msg_id"], row["msg_seq"] or 1
        attempts = row["attempts"] + 1
        image = row["kind"] == "image"
        status, channel, error = "failed", None, None
        for _ in range(3):
            passive = bool(msg_id) and bool(row["msg_at"]) and now <= parse(row["msg_at"]) + PASSIVE_WINDOW
            payload = {"content": "" if image else row["text"][:SEND_LIMIT], "msg_type": 7 if image else 0}
            if passive:
                payload.update(msg_id=msg_id, msg_seq=seq)
            channel = "passive" if passive else "active"
            try:
                if image:
                    info = await self._upload(http, row["openid"], row["text"])
                    if not info:
                        error = "表情包素材已删除，这张图发不出去了"
                        break
                    payload["media"] = {"file_info": info}
                    # 一张图 + 一句话的两条消息会撞同一个 msg_seq，图片让一位。
                    if passive:
                        payload["msg_seq"] = seq + 50
                code, data = await self._call(http, "POST", f"/v2/users/{quote(row['openid'])}/messages", payload)
            except httpx.TimeoutException:
                status, error = "unknown", "请求已发出但没有收到 QQ 的答复，是否送达未知，不会自动重发"
                break
            except httpx.TransportError as exc:
                if attempts <= len(RETRY_DELAYS):
                    with self.store.connect() as conn:
                        conn.execute("UPDATE qq_outbox SET status='queued', not_before=?, last_error=? WHERE id=?",
                                     (stamp(now + timedelta(seconds=RETRY_DELAYS[attempts - 1])),
                                      f"连不上 QQ 服务器：{type(exc).__name__}", row["id"]))
                    return
                error = f"多次连不上 QQ 服务器：{type(exc).__name__}"
                break
            except DomainError as exc:
                error = exc.message
                break
            errcode = data.get("code") or data.get("err_code") or data.get("errCode")
            if not errcode:
                status = "sent"
                break
            if passive and errcode in PASSIVE_LOST:
                msg_id = None  # 被动凭证过了，改走主动消息
                continue
            if errcode in DUPLICATE and passive:
                seq += 1
                with self.store.connect() as conn:
                    conn.execute("UPDATE qq_outbox SET msg_seq=? WHERE id=?", (seq, row["id"]))
                continue
            if errcode in RATE_LIMITED and attempts <= len(RETRY_DELAYS):
                with self.store.connect() as conn:
                    conn.execute("UPDATE qq_outbox SET status='queued', not_before=?, last_error=? WHERE id=?",
                                 (stamp(now + timedelta(seconds=RETRY_DELAYS[attempts - 1])),
                                  f"{errcode}：{ERR_HINTS.get(errcode, 'QQ 限频')}", row["id"]))
                return
            hint = ERR_HINTS.get(errcode)
            error = (f"{errcode}：{hint}" if hint else f"{errcode}：{data.get('message', '')}")[:300]
            break
        with self.store.connect() as conn:
            conn.execute("UPDATE qq_outbox SET status=?, channel=?, last_error=?, sent_at=? WHERE id=?",
                         (status, channel, error, stamp(self.clock()) if status == "sent" else None, row["id"]))

    # ---- Worker ----------------------------------------------------------
    async def run_once(self):
        """Process waiting inbound messages, then send what is due. Serialised."""
        async with self.lock:
            with self.store.connect() as conn:
                pending = conn.execute("SELECT * FROM qq_inbox WHERE status IN ('pending','processing') "
                                       "ORDER BY received_at, rowid").fetchall()
            for row in pending:
                with self.store.connect() as conn:
                    conn.execute("UPDATE qq_inbox SET status='processing' WHERE id=?", (row["id"],))
                try:
                    reply = await self.commands.reply(row["content"], request_id=row["id"])
                    status = "done"
                except Exception as error:  # noqa: BLE001 - 队列不能停，证据要留下
                    log.exception("QQ message handling failed")
                    reply, status = "这条消息处理出错了，已记下，稍后再试一次？", f"failed:{type(error).__name__}"
                with self.store.connect() as conn:
                    conn.execute("UPDATE qq_inbox SET status=? WHERE id=?", (status[:60], row["id"]))
                    self._enqueue(conn, row["openid"], reply, self.clock(), key=f"reply:{row['id']}",
                                  msg_id=row["msg_id"], msg_at=parse(row["received_at"]))
                    category = getattr(self.commands, "meme", "")
                    name = memes.pick(category) if category else None
                    if name:  # 文字在前，图在后：同一 not_before 下按 rowid 定序
                        self._enqueue_meme(conn, row["openid"], name, self.clock(),
                                           key=f"reply:{row['id']}", msg_id=row["msg_id"],
                                           msg_at=parse(row["received_at"]))
            if not self.settings.configured():
                return
            with self.store.connect() as conn:
                due = conn.execute("SELECT * FROM qq_outbox WHERE status='queued' AND not_before<=? "
                                   "ORDER BY not_before, rowid LIMIT 20", (stamp(self.clock()),)).fetchall()
            if not due:
                return
            async with httpx.AsyncClient(timeout=15, transport=self.transport()) as http:
                for row in due:
                    await self.deliver(http, row)

    async def serve(self):
        """Keep the bot WebSocket connected for as long as the backend runs."""
        delay = 5
        while True:
            if not self.settings.configured():
                self.connected = False
                await asyncio.sleep(delay)
                continue
            try:
                if await self._session():
                    delay = 5
                else:
                    delay = min(delay * 2, 120)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - 断线是常态，重连即可
                log.exception("QQ 长连接断开，稍后重连")
                delay = min(delay * 2, 120)
            self.connected = False
            await asyncio.sleep(delay)

    async def _session(self):
        """One gateway connection. Returns True once QQ said READY."""
        async with httpx.AsyncClient(timeout=20, transport=self.transport()) as http:
            token = await self._access_token(http)
            gateway = await self._gateway(http, token)
        async with self.connect(gateway) as socket:
            hello = json.loads(await asyncio.wait_for(socket.recv(), timeout=30))
            heartbeat = float((hello.get("d") or {}).get("heartbeat_interval") or 30000) / 1000
            await socket.send(json.dumps({"op": OP_IDENTIFY, "d": {
                "token": f"QQBot {token}", "intents": INTENTS, "shard": [0, 1],
                "properties": {"$os": "windows", "$browser": "timer", "$device": "timer"}}}))
            seq, ready = None, False
            while True:
                try:
                    raw = await asyncio.wait_for(socket.recv(), timeout=heartbeat)
                except asyncio.TimeoutError:
                    await socket.send(json.dumps({"op": OP_HEARTBEAT, "d": seq}))
                    continue
                frame = json.loads(raw)
                if frame.get("s") is not None:
                    seq = frame["s"]
                op = frame.get("op")
                if op == OP_HELLO:
                    heartbeat = float((frame.get("d") or {}).get("heartbeat_interval") or 30000) / 1000
                elif op == OP_DISPATCH:
                    name = frame.get("t") or ""
                    if name == "READY":
                        ready = self.connected = True
                    elif name == "C2C_MESSAGE_CREATE":
                        task = asyncio.create_task(self._on_message(frame.get("d") or {}))
                        self._tasks.add(task)
                        task.add_done_callback(self._tasks.discard)
                elif op in (OP_RECONNECT, OP_INVALID_SESSION):
                    return ready
                elif op == OP_HEARTBEAT_ACK:
                    continue

    async def _on_message(self, data):
        try:
            if self.receive(data):
                await self.run_once()
        except Exception:  # noqa: BLE001 - 单条消息失败不能拖垮长连接
            log.exception("QQ 消息处理失败")
