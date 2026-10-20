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
from zoneinfo import ZoneInfo

import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .domain import DomainError, identifier, parse, stamp

API = "https://api.weixin.qq.com"
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
HELP = ("我是你的瞬时助手。\n"
        "· 直接说想安排什么，比如「明晚八点学两小时算法」\n"
        "· 「今天」查看今天的安排\n"
        "· 我会直接改好日程，不对就回复「撤销」\n"
        "· 到点后可回复「完成了」或「再给我15分钟」\n"
        "· 「今日总结：……」保存原文，「记住：……」保存偏好\n"
        "· 「取消 某某」「把午饭挪到一点」也可以直接说")
UNDO = re.compile(r"^(撤销|撤回|undo)\s*([0-9a-fA-F]{4})?$", re.IGNORECASE)
CONFIRM = re.compile(r"^(确认|照办|照此办理|办|好的?|可以|ok)\s*([0-9a-fA-F]{4})?$", re.IGNORECASE)
DISMISS = re.compile(r"^(不必|算了|不用了?|放下)\s*([0-9a-fA-F]{4})?$")
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
        bound = conf["bound_openid"]
        with self.store.connect() as conn:
            inserted = conn.execute(
                "INSERT OR IGNORE INTO wechat_inbox VALUES(?,?,?,?,?,?,?,?)",
                (identifier(), dedup, openid, kind, content, stamp(now), "new", None)).rowcount
            if not inserted:
                return False  # WeChat retried a message we already have.
            def mark(status, note=None):
                conn.execute("UPDATE wechat_inbox SET status=?, note=? WHERE dedup_key=?", (status, note, dedup))

            is_code = kind == "text" and re.fullmatch(r"\d{6}", content) is not None
            if is_code and self._bind_code_matches(conf, content, now):
                # A valid code binds (or re-binds) whoever sent it; it works once.
                conf.update(bound_openid=openid, bound_at=stamp(now), bind_code_hash=None, bind_expires_at=None)
                self.settings.save(conf)
                mark("done", "bound")
                self._enqueue(conn, openid, "绑定好了。以后在这里跟我说要安排什么就行。\n\n" + HELP, now)
                return True
            if not bound:
                if is_code:
                    mark("done", "bad code")
                    self._enqueue(conn, openid, "这个绑定码不对或已经过期了，请在电脑上的瞬时里重新生成。", now)
                else:
                    mark("ignored", "not bound")
                return True
            if openid != bound:
                mark("ignored", "other account")
                return True
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

    async def handle(self, text, request_id=None):
        """Reply text for one bound-user message."""
        compact = text.strip()
        command = re.fullmatch(r"(完成了?|结束并完成|再给我(?:15|30)分钟|续时(?:15|30)分钟)(?:\s+([0-9a-fA-F]{6}))?", compact)
        review = re.fullmatch(r"今日总结[：:]\s*(.{1,10000})", compact, re.S)
        operation_id = f"wechat-command:{request_id}" if request_id else None
        if operation_id:
            with self.store.connect() as conn:
                previous = conn.execute('SELECT response FROM operations WHERE id=?', (operation_id,)).fetchone()
            if previous:
                return '这条反馈已经记录，日程已同步。'
        if review:
            day = self.clock().astimezone(ZoneInfo(self.store.state()['settings']['timezone'])).date().isoformat()
            self.assistant.apply_operation('review.save', {'date': day, 'text': review.group(1)}, 'wechat', operation_id)
            return '今日原文已保留并安排电脑归档。材料复盘可在瞬时的回顾页生成。'
        if command:
            from .maintenance import expire_due
            expire_due(self.store, self.clock())
            state = self.store.state()
            candidates = [s for s in state['sessions'] if s['state'] in ('running', 'paused', 'awaiting_feedback')]
            if command.group(2):
                candidates = [s for s in candidates if s['id'].startswith(command.group(2).lower())]
            if len(candidates) != 1:
                return '请说明是哪一段，或打开瞬时选择待回话的任务。'
            session = candidates[0]
            if command.group(1).startswith(('再给我', '续时')):
                minutes = int(re.search(r'15|30', command.group(1)).group())
                try:
                    changed = self.assistant.apply_operation('session.extend', {'id': session['id'], 'minutes': minutes}, 'wechat', operation_id)['entity']
                    end = parse(changed['expected_end_at']).astimezone(ZoneInfo(state['settings']['timezone']))
                    adjustment = changed.get('adjustment', {}).get('status')
                    tail = '后续弹性安排已顺延。' if adjustment == 'applied' else '后续有冲突或需要确认，请到瞬时查看调整。' if adjustment in ('proposal', 'blocked') else ''
                    return f'已增加 {minutes} 分钟，预计 {end:%H:%M} 收尾。{tail}'
                except DomainError as error:
                    return error.message
            if session['state'] in ('running', 'paused'):
                self.assistant.apply_operation('session.end', {'id': session['id']}, 'wechat', f'wechat-end:{request_id}' if request_id else None)
            self.assistant.apply_operation('feedback.create', {'session_id': session['id'], 'choice': 'done', 'outcome_text': '用户在微信确认完成'}, 'wechat', operation_id)
            return '已记录完成，相关追问已停止。'
        if compact in ("帮助", "help", "?", "？"):
            return HELP
        if compact in ("今天", "今日", "今天的安排"):
            return self.today_summary()
        if compact in ('记忆', '你记住了什么'):
            memories = self.store.state().get('memories', [])
            return '\n'.join(['你明确让我记住的事：', *[m['text'] for m in memories]]) if memories else '目前还没有保存的长期偏好。'
        undo = UNDO.match(compact)
        if undo:
            return self.undo(undo.group(2))
        match = CONFIRM.match(compact) or DISMISS.match(compact)
        if match:
            answer = self.decide(bool(CONFIRM.match(compact)), match.group(2))
            if answer is not None:
                return answer
        try:
            rows = await self.assistant.converse(compact, request_id=request_id, device_id="wechat")
        except DomainError as error:
            if error.code == "ASSISTANT_NOT_CONFIGURED":
                return "模型服务还没在电脑上配置好，我暂时只能回答「今天」「帮助」。"
            return error.message
        reply = rows[-1]
        lines = [reply["text"]]
        for draft in reply["drafts"]:
            code = draft["id"][:4].upper()
            if draft["status"] == "applied":
                lines += [f"· {line}" for line in draft["lines"]]
                if draft["undoable"]:
                    lines.append(f"不对的话回复「撤销 {code}」。")
            elif draft["status"] == "pending":
                lines += ["", f"【拟办 {code}】{draft['summary']}", *(f"· {line}" for line in draft["lines"]),
                          f"回复「确认 {code}」照此办理，「不必 {code}」放下。"]
        return "\n".join(lines)

    def undo(self, code):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT d.id, d.summary, d.created_at FROM assistant_drafts d JOIN assistant_undo u "
                                "ON u.draft_id=d.id WHERE d.status='applied' ORDER BY d.created_at DESC").fetchall()
        if code:
            matches = [r for r in rows if r["id"][:4].lower() == code.lower()]
        else:  # A bare "撤销" means the assistant's latest change, if it is recent.
            matches = [r for r in rows[:1] if parse(r["created_at"]) >= self.clock() - timedelta(minutes=30)]
        if len(matches) != 1:
            return "没有找到可以撤销的这条改动，可能已经撤销过了。请到瞬时的助手页查看。"
        try:
            self.assistant.undo_draft(matches[0]["id"], "wechat")
        except DomainError as error:
            return error.message
        return f"已撤销：{matches[0]['summary']}。"

    def decide(self, accept, code):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT id, summary, created_at FROM assistant_drafts WHERE status='pending' "
                                "ORDER BY created_at DESC").fetchall()
        if code:
            matches = [r for r in rows if r["id"][:4].lower() == code.lower()]
        else:  # A bare "确认" only counts when exactly one recent draft is waiting.
            recent = self.clock() - timedelta(minutes=30)
            matches = [r for r in rows if parse(r["created_at"]) >= recent]
            if not matches:
                return None  # Just a casual "好"; let the assistant answer it.
            if len(matches) > 1:
                codes = "、".join(r["id"][:4].upper() for r in matches)
                return f"现在有几条拟办在等你：{codes}。请带上编号，比如「确认 {matches[0]['id'][:4].upper()}」。"
        if not matches:
            return "没有找到等你确认的这条拟办，可能已经处理过或过期了。"
        if len(matches) > 1:
            return "这个编号对应了不止一条拟办，请到 App 的助手页确认。"
        draft = matches[0]
        try:
            if accept:
                result = self.assistant.apply_draft(draft["id"], "wechat")
                return f"已照此办理：{draft['summary']}。"
            self.assistant.dismiss_draft(draft["id"])
            return f"好，放下了：{draft['summary']}。"
        except DomainError as error:
            return f"没能执行：{error.message}"

    def today_summary(self):
        state = self.store.state()
        zone = ZoneInfo(state["settings"]["timezone"])
        now = self.clock().astimezone(zone)
        blocks = sorted((b for b in state["blocks"] if b["status"] in ("scheduled", "completed", "skipped")
                         and parse(b["start_at"]).astimezone(zone).date() == now.date()),
                        key=lambda b: b["start_at"])
        if not blocks:
            return f"{now:%m月%d日}还没有安排。想做什么，直接告诉我。"
        marks = {"completed": "✓ ", "skipped": "· 未开始 "}
        lines = [f"{now:%m月%d日}的安排："]
        for block in blocks:
            start = parse(block["start_at"]).astimezone(zone)
            end = parse(block["end_at"]).astimezone(zone)
            lines.append(f"{marks.get(block['status'], '')}{start:%H:%M}–{end:%H:%M} {block['title']}")
        return "\n".join(lines)

    # ---- Outbound --------------------------------------------------------
    @staticmethod
    def chunks(text, size=600):
        """Split at paragraph or line breaks so each message stays within WeChat's limit."""
        parts, current = [], ""
        for line in text.split("\n"):
            while len(line) > size:
                if current:
                    parts.append(current)
                    current = ""
                parts.append(line[:size])
                line = line[size:]
            candidate = f"{current}\n{line}" if current else line
            if len(candidate) > size:
                parts.append(current)
                current = line
            else:
                current = candidate
        if current or not parts:
            parts.append(current)
        return parts

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
            for row in pending:
                with self.store.connect() as conn:
                    conn.execute("UPDATE wechat_inbox SET status='processing' WHERE id=?", (row["id"],))
                try:
                    reply = await self.handle(row["content"], request_id=row['id'])
                    status = "done"
                except Exception as error:  # noqa: BLE001 - keep the queue moving, keep the evidence
                    log.exception("WeChat message handling failed")
                    reply, status = "这条消息处理出错了，已记下，稍后再试一次？", f"failed:{type(error).__name__}"
                with self.store.connect() as conn:
                    conn.execute("UPDATE wechat_inbox SET status=? WHERE id=?", (status[:60], row["id"]))
                    self._enqueue(conn, row["openid"], reply, self.clock(), key=f"reply:{row['id']}")
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
