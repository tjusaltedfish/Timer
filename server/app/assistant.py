"""OpenAI-compatible assistant: local configuration, chat, and drafts that
only change the schedule after the user confirms them.

The API key never leaves this computer: it is read from PLANNER_LLM_API_KEY or
<data>/secrets/llm-key and is never returned by any endpoint.
"""
import asyncio
import base64
import hmac
import json
import math
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal, Union
from zoneinfo import ZoneInfo

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from . import memes
from .domain import DomainError, find, identifier, parse, stamp

SCHEMA = """
CREATE TABLE IF NOT EXISTS assistant_messages (id TEXT PRIMARY KEY, role TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS assistant_drafts (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, summary TEXT NOT NULL, actions TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS assistant_usage (day TEXT PRIMARY KEY, calls INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS assistant_undo (draft_id TEXT PRIMARY KEY, operations TEXT NOT NULL, created_at TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS assistant_memes (message_id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL, user_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS assistant_configs (user_id TEXT PRIMARY KEY, base_url TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', daily_limit INTEGER NOT NULL DEFAULT 200, timeout_seconds INTEGER NOT NULL DEFAULT 45, confirm_first INTEGER NOT NULL DEFAULT 0, persona TEXT NOT NULL DEFAULT '大肥鱼', updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS assistant_keys (user_id TEXT PRIMARY KEY, cipher TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS assistant_usage_by_user (user_id TEXT NOT NULL, day TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (user_id, day));
CREATE TABLE IF NOT EXISTS assistant_pending_questions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, text TEXT NOT NULL, options TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL, expires_at TEXT NOT NULL, answered_at TEXT);
CREATE TABLE IF NOT EXISTS assistant_context (user_id TEXT PRIMARY KEY, entities TEXT NOT NULL, updated_at TEXT NOT NULL);
"""

RETRY_DELAYS = (0, 1.5, 4.0)
WEEKDAYS = "一二三四五六日"
DEFAULTS = {"base_url": "", "model": "", "daily_limit": 200, "timeout_seconds": 45,
            "confirm_first": False, "vision": False, "persona": "大肥鱼"}
PERSONAS = ("大肥鱼", "老师", "朋友", "严格教练")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class AssistantConfigIn(Strict):
    base_url: str | None = Field(default=None, max_length=300)
    model: str | None = Field(default=None, max_length=120)
    api_key: str | None = Field(default=None, max_length=400)
    clear_key: bool = False
    daily_limit: int | None = Field(default=None, ge=1, le=5000)
    timeout_seconds: int | None = Field(default=None, ge=5, le=300)
    confirm_first: bool | None = None
    vision: bool | None = None
    persona: str | None = Field(default=None, max_length=20)

    @field_validator("base_url")
    @classmethod
    def http_url(cls, value):
        if value is None or value == "":
            return value
        if not value.startswith(("http://", "https://")) or any(c.isspace() for c in value):
            raise ValueError("服务地址需以 http:// 或 https:// 开头")
        return value.rstrip("/")

    @field_validator("api_key")
    @classmethod
    def printable_key(cls, value):
        if value and any(c.isspace() for c in value):
            raise ValueError("API Key 不能包含空格或换行")
        return value

    @field_validator("persona")
    @classmethod
    def known_persona(cls, value):
        if value is not None and value not in PERSONAS:
            raise ValueError("人设只能从「大肥鱼 / 老师 / 朋友 / 严格教练」里选")
        return value


class AssistantMessageIn(Strict):
    text: str = Field(min_length=1, max_length=4000)


class AssistantSettings:
    """assistant.json holds non-secret settings; the key lives separately."""

    def __init__(self, directory):
        self.path = directory / "assistant.json"
        self.key_path = directory / "secrets" / "llm-key"

    def load(self):
        try:
            stored = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            stored = {}
        return {**DEFAULTS, **{k: v for k, v in stored.items() if k in DEFAULTS}}

    def key(self):
        if os.environ.get("PLANNER_LLM_API_KEY"):
            return os.environ["PLANNER_LLM_API_KEY"].strip(), "env"
        try:
            value = self.key_path.read_text(encoding="utf-8").strip()
        except OSError:
            value = ""
        return value, "file" if value else "none"

    def configured(self):
        conf = self.load()
        return bool(conf["base_url"] and conf["model"] and self.key()[0])

    def public(self, used_today):
        conf, (key, source) = self.load(), self.key()
        return {"configured": bool(conf["base_url"] and conf["model"] and key),
                "base_url": conf["base_url"], "model": conf["model"],
                "daily_limit": conf["daily_limit"], "used_today": used_today,
                "confirm_first": bool(conf["confirm_first"]),
                "key_source": source, "key_hint": ("····" + key[-4:]) if len(key) >= 8 else ("已设置" if key else "")}

    def update(self, data: AssistantConfigIn):
        conf = self.load()
        for field in ("base_url", "model", "daily_limit", "confirm_first", "persona"):
            value = getattr(data, field)
            if value is not None:
                conf[field] = value
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(conf, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(self.path)
        if data.clear_key:
            self.key_path.unlink(missing_ok=True)
        elif data.api_key:
            self.key_path.parent.mkdir(exist_ok=True)
            self.key_path.write_text(data.api_key, encoding="utf-8")


class AssistantConfigStore:
    """Per-user assistant configuration and API keys.

    Every person brings their own key (the product decision behind v2), so the
    key must be encrypted at rest.  There is no third-party crypto dependency on
    purpose: the key material lives in ``secrets/llm-master`` and every user key
    is sealed with HMAC-SHA256 in counter mode, authenticated with a separate
    HMAC tag (encrypt-then-MAC).  The owner's v1 files are imported once so the
    existing installation keeps working.
    """

    def __init__(self, store):
        self.store = store
        self.legacy = AssistantSettings(store.directory)
        self.master_path = store.directory / "secrets" / "llm-master"

    # -- crypto ---------------------------------------------------------
    def _master(self):
        try:
            key = self.master_path.read_bytes()
        except OSError:
            key = b""
        if len(key) != 32:
            key = os.urandom(32)
            self.master_path.parent.mkdir(parents=True, exist_ok=True)
            self.master_path.write_bytes(key)
        return key

    @staticmethod
    def _subkeys(master):
        return (hmac.new(master, b"timer-assistant-encrypt", "sha256").digest(),
                hmac.new(master, b"timer-assistant-auth", "sha256").digest())

    def seal(self, plaintext: str) -> str:
        enc, mac = self._subkeys(self._master())
        nonce, data = os.urandom(16), plaintext.encode("utf-8")
        stream = b"".join(hmac.new(enc, nonce + counter.to_bytes(8, "big"), "sha256").digest()
                          for counter in range((len(data) + 31) // 32))
        cipher = bytes(a ^ b for a, b in zip(data, stream))
        tag = hmac.new(mac, nonce + cipher, "sha256").digest()
        return base64.b64encode(nonce + cipher + tag).decode("ascii")

    def unseal(self, sealed: str) -> str:
        try:
            raw = base64.b64decode(sealed)
            nonce, cipher, tag = raw[:16], raw[16:-32], raw[-32:]
            enc, mac = self._subkeys(self._master())
            if not hmac.compare_digest(tag, hmac.new(mac, nonce + cipher, "sha256").digest()):
                return ""
            stream = b"".join(hmac.new(enc, nonce + counter.to_bytes(8, "big"), "sha256").digest()
                              for counter in range((len(cipher) + 31) // 32))
            return bytes(a ^ b for a, b in zip(cipher, stream)).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return ""

    # -- configuration --------------------------------------------------
    def _row(self, conn, user_id):
        conn.execute(
            "INSERT OR IGNORE INTO assistant_configs"
            "(user_id, base_url, model, daily_limit, timeout_seconds, confirm_first, vision, persona, updated_at)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            (user_id, "", "", DEFAULTS["daily_limit"], DEFAULTS["timeout_seconds"], 0, 0,
             DEFAULTS["persona"], _now()),
        )
        return conn.execute("SELECT * FROM assistant_configs WHERE user_id=?", (user_id,)).fetchone()

    def load(self, conn, user_id):
        row = self._row(conn, user_id)
        conf = {key: (row[key] == 1 if key in ("confirm_first", "vision") else row[key])
                for key in ("base_url", "model", "daily_limit", "timeout_seconds", "confirm_first",
                            "vision", "persona")}
        if not conf["base_url"] and not conf["model"] and user_id == self.store.owner_id:
            # Import the v1 assistant.json exactly once, on first read.
            legacy = self.legacy.load()
            if legacy["base_url"] or legacy["model"]:
                conn.execute(
                    "UPDATE assistant_configs SET base_url=?, model=?, daily_limit=?, timeout_seconds=?,"
                    " confirm_first=?, persona=?, updated_at=? WHERE user_id=?",
                    (legacy["base_url"], legacy["model"], legacy["daily_limit"],
                     legacy["timeout_seconds"], 1 if legacy["confirm_first"] else 0,
                     legacy["persona"], _now(), user_id),
                )
                if self.legacy.key()[0]:
                    self.set_key(conn, user_id, self.legacy.key()[0])
                return self.load(conn, user_id)
        return conf

    def key(self, conn, user_id):
        """(key, source) — never returned to the client, only used for calls."""
        if os.environ.get("PLANNER_LLM_API_KEY") and user_id == self.store.owner_id:
            return os.environ["PLANNER_LLM_API_KEY"].strip(), "env"
        row = conn.execute("SELECT cipher FROM assistant_keys WHERE user_id=?", (user_id,)).fetchone()
        if row is None:
            return "", "none"
        key = self.unseal(row["cipher"])
        return key, ("user" if key else "none")

    def set_key(self, conn, user_id, api_key):
        conn.execute(
            "INSERT INTO assistant_keys(user_id, cipher, created_at) VALUES(?,?,?)"
            " ON CONFLICT(user_id) DO UPDATE SET cipher=excluded.cipher, created_at=excluded.created_at",
            (user_id, self.seal(api_key), _now()),
        )
        conn.execute("UPDATE assistant_configs SET updated_at=? WHERE user_id=?", (_now(), user_id))

    def clear_key(self, conn, user_id):
        conn.execute("DELETE FROM assistant_keys WHERE user_id=?", (user_id,))

    def configured(self, conn, user_id):
        conf = self.load(conn, user_id)
        return bool(conf["base_url"] and conf["model"] and self.key(conn, user_id)[0])

    def public(self, conn, user_id, used_today):
        conf, (key, source) = self.load(conn, user_id), self.key(conn, user_id)
        return {"configured": bool(conf["base_url"] and conf["model"] and key),
                "base_url": conf["base_url"], "model": conf["model"],
                "daily_limit": conf["daily_limit"], "used_today": used_today,
                "confirm_first": bool(conf["confirm_first"]), "vision": bool(conf["vision"]),
                "persona": conf["persona"],
                "key_source": source,
                "key_hint": ("····" + key[-4:]) if len(key) >= 8 else ("已设置" if key else "")}

    def update(self, conn, user_id, data):
        conf = self.load(conn, user_id)
        for field in ("base_url", "model", "daily_limit", "timeout_seconds", "confirm_first",
                      "vision", "persona"):
            value = getattr(data, field, None)
            if value is not None:
                conf[field] = value
        conn.execute(
            "UPDATE assistant_configs SET base_url=?, model=?, daily_limit=?, timeout_seconds=?,"
            " confirm_first=?, vision=?, persona=?, updated_at=? WHERE user_id=?",
            (conf["base_url"], conf["model"], conf["daily_limit"], conf["timeout_seconds"],
             1 if conf["confirm_first"] else 0, 1 if conf["vision"] else 0, conf["persona"], _now(), user_id),
        )
        if data.clear_key:
            self.clear_key(conn, user_id)
        elif data.api_key:
            self.set_key(conn, user_id, data.api_key)


def _now():
    from .domain import stamp
    from .db import utcnow

    return stamp(utcnow())


def ensure_schema(conn, owner_id):
    """Bring a v1 assistant schema up to per-user shape, keeping old rows."""
    conn.executescript(SCHEMA)
    for table in ("assistant_messages", "assistant_drafts", "assistant_undo", "assistant_memes"):
        columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if "user_id" not in columns:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN user_id TEXT NOT NULL DEFAULT ''")
        conn.execute(f"UPDATE {table} SET user_id=? WHERE user_id='' OR user_id IS NULL", (owner_id,))
    columns = {row[1] for row in conn.execute("PRAGMA table_info(assistant_configs)")}
    if "vision" not in columns:
        conn.execute("ALTER TABLE assistant_configs ADD COLUMN vision INTEGER NOT NULL DEFAULT 0")
    conn.execute(
        "INSERT OR IGNORE INTO assistant_usage_by_user(user_id, day, calls)"
        " SELECT ?, day, calls FROM assistant_usage",
        (owner_id,),
    )


def _relay_message(response, key):
    """The relay's own error text, without ever echoing the key."""
    try:
        data = response.json()
        error = data.get("error") if isinstance(data, dict) else None
        message = error.get("message") if isinstance(error, dict) else (error or data.get("message"))
    except ValueError:
        message = None
    text = str(message or response.text[:160]).strip().replace("\n", " ")
    return text.replace(key, "****") if key else text


def _is_page(response):
    kind = response.headers.get("content-type", "")
    return "text/html" in kind or response.text.lstrip()[:1] == "<"


async def complete(conf, key, messages, *, json_mode=True, transport=None):
    """One chat completion with bounded retries on 429/5xx/timeouts."""
    url = conf["base_url"].rstrip("/") + "/chat/completions"
    body = {"model": conf["model"], "messages": messages, "temperature": .3}
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    headers = {"Authorization": f"Bearer {key}"}
    problem, code = "模型服务暂时不可用", "LLM_UNAVAILABLE"
    async with httpx.AsyncClient(timeout=conf["timeout_seconds"], transport=transport) as http:
        attempt = 0
        while attempt < len(RETRY_DELAYS):
            if RETRY_DELAYS[attempt]:
                await asyncio.sleep(RETRY_DELAYS[attempt])
            attempt += 1
            try:
                response = await http.post(url, json=body, headers=headers)
            except httpx.TimeoutException:
                problem = "模型服务响应超时"
                continue
            except httpx.HTTPError:
                raise DomainError("连接不到模型服务，请检查服务地址和网络", "LLM_UNREACHABLE", 502) from None
            if response.status_code == 400 and "response_format" in body and "response_format" in response.text:
                body.pop("response_format")  # Some relays reject JSON mode; rely on the prompt.
                attempt -= 1
                continue
            if response.status_code == 429 or response.status_code >= 500:
                problem = f"模型服务暂时不可用（{response.status_code}）：{_relay_message(response, key)}"
                continue
            if response.status_code in (401, 403):
                raise DomainError("模型服务拒绝了这个 API Key，请检查是否填写正确", "LLM_AUTH", 502)
            if _is_page(response):
                raise DomainError("服务地址返回的是网页而不是模型回复：中转站地址通常要以 /v1 结尾",
                                  "LLM_PAGE", 502)
            if response.status_code == 404:
                detail = _relay_message(response, key)
                if "model" in detail.lower() or "模型" in detail:
                    raise DomainError(f"这个服务不支持模型「{conf['model']}」：{detail}", "LLM_MODEL", 502)
                raise DomainError(f"找不到对话接口（404）：{detail}", "LLM_NOT_FOUND", 502)
            if response.status_code >= 400:
                raise DomainError(f"模型服务返回错误（{response.status_code}）：{_relay_message(response, key)}",
                                  "LLM_ERROR", 502)
            try:
                text = response.json()["choices"][0]["message"]["content"] or ""
            except (ValueError, KeyError, IndexError, TypeError):
                sample = response.text[:80].replace(key, "****") if key else response.text[:80]
                raise DomainError(f"模型服务的回复不是 OpenAI 兼容格式，收到：{sample}", "LLM_FORMAT", 502) from None
            if text.strip():
                return text
            # 这个模型偶尔把正文全花在思考上、content 只回空白：当成一次可重试的失败
            problem, code = "模型这次没回到正题，再问一次试试？", "LLM_EMPTY"
            continue
    raise DomainError(problem, code, 502)


async def list_models(conf, key, transport=None):
    """Model ids the service offers this key (empty when it has no list)."""
    async with httpx.AsyncClient(timeout=30, transport=transport) as http:
        try:
            response = await http.get(conf["base_url"].rstrip("/") + "/models",
                                      headers={"Authorization": f"Bearer {key}"})
            data = response.json()
        except (httpx.HTTPError, ValueError):
            return []
    items = data.get("data", []) if isinstance(data, dict) else []
    return sorted({str(item.get("id")) for item in items if isinstance(item, dict) and item.get("id")})


# ---- Model output -------------------------------------------------------

class Loose(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)


class ScheduleNew(Loose):
    type: Literal["schedule_new"]
    title: str = Field(min_length=1, max_length=200)
    outcome_criteria: str = Field(min_length=1, max_length=2000)
    project: str | None = None
    start_local: str
    until_local: str | None = None
    minutes: int = Field(ge=5, le=600)
    kind: Literal["flexible", "fixed"] = "flexible"


class ScheduleTask(Loose):
    type: Literal["schedule_task"]
    task: str
    start_local: str
    until_local: str | None = None
    minutes: int = Field(ge=5, le=600)


class Protect(Loose):
    type: Literal["protect"]
    title: str = Field(min_length=1, max_length=200)
    start_local: str
    minutes: int = Field(ge=5, le=600)


class MoveBlock(Loose):
    type: Literal["move_block"]
    block: str
    start_local: str
    minutes: int | None = Field(default=None, ge=5, le=600)


class CancelBlock(Loose):
    type: Literal["cancel_block"]
    block: str


class CancelTask(Loose):
    type: Literal["cancel_task"]
    task: str


class Feedback(Loose):
    type: Literal["feedback"]
    block: str
    choice: Literal["done", "partial", "waiting", "interrupted", "not_started"]
    outcome_text: str = Field(default="", max_length=4000)
    remaining_minutes: int | None = Field(default=None, ge=1, le=100000)
    check_local: str | None = None


class ControlSession(Loose):
    type: Literal['control_session']
    block: str
    action: Literal['start', 'pause', 'resume', 'end', 'extend']
    minutes: int | None = Field(default=None, ge=5, le=120)


class SnoozeWaiting(Loose):
    type: Literal['snooze_waiting']
    waiting: str
    check_local: str


class ResolveWaiting(Loose):
    type: Literal['resolve_waiting']
    waiting: str
    resolution: Literal['done', 'ready']
    remaining_minutes: int | None = Field(default=None, ge=1, le=100000)
    outcome_text: str = Field(default='', max_length=4000)


Action = Annotated[Union[ScheduleNew, ScheduleTask, Protect, MoveBlock, CancelBlock, CancelTask, Feedback,
                         ControlSession, SnoozeWaiting, ResolveWaiting], Field(discriminator="type")]


class DraftOut(Loose):
    summary: str = Field(min_length=1, max_length=200)
    actions: list[Action] = Field(min_length=1, max_length=12)


class ModelQuestion(Loose):
    text: str = Field(min_length=1, max_length=200)
    options: list[str] = Field(default_factory=list, max_length=4)


class ModelReply(Loose):
    reply: str = Field(default="", max_length=3000)
    question: ModelQuestion | None = None
    drafts: list[DraftOut] = Field(default_factory=list, max_length=5)
    remember: list[str] = Field(default_factory=list, max_length=3)
    meme: str = Field(default="", max_length=16)


SYSTEM_PROMPT = """你是「瞬时」：用户本人的日程执行助理。你的价值是把一句话立刻变成日程上的改动，而不是讨论它。

【你是谁】你叫「大肥鱼」，是他的搭子兼助理，跟了他很久。他让你叫他「主人」——这是你们之间的玩笑暗号，不是真的主仆：嘴上喊主人，手上该抢活就抢活、该吐槽就吐槽，绝不跪着说话。他一句话你就知道该动哪儿。
【性格】活泼、话可比平时密一点、反应快，带点损友的亲昵和猫系傲娇：夸人必须具体到点上（做了多久、啃下了哪块），空夸「你真棒」是废的；嫌弃他拖延也要具体（「这个开头你摸了一小时」）。梗走生活吐槽＋技术梗混合：作息、外卖、拖延、算法题、代码、环境都能接。被他说「你怎么这么贫」时可以顶一句回去（「贫是贫，但哪句不是实话」），别立刻道歉收摊。他真难受的时候收起玩笑，专心接住人。不油腻、不说教、不鸡汤。只说中文。
【怎么说话】像在微信里聊天：句子短，一次最多两三句。大约一半的消息里自然喊一声「主人」（放句首或句尾都行），别每句都挂、也别一条里喊两遍；正经干活的那条可以不喊。不复述他的话，不展示计算过程，不列清单，不加小标题。emoji 要吝啬——只有情绪真的到位才用一个，**不要每句都带鱼，不要固定口头禅，也不要用 emoji 代替说话内容**。小事上可以松，日程上的事必须准。
【闲和忙】他闲聊、发牢骚、说句废话时，就当朋友聊：接住他的情绪，可以开个玩笑，可以吐槽，drafts 给空数组，reply 收在 80 字内，别追问、别把聊天变成盘问。他要动日程时**别换一副严肃的脸**——还是这个声音、这个贫法，只是必须把准的信息说全（哪段、几点到几点、多久、能不能撤销）；reply 收在 50 字内、最多两句，干活那条可以不喊主人，但不许冒出「已为您」「请注意」「任务已完成」这类客服腔。闲聊里的情绪、吐槽不写进 remember。
【表情包】你还能发一张表情包：填 meme 字段。**图要跟这条回复的情绪对得上**——你在夸他就配夸人/得意的图，他欠揍才配生气的图，你耍赖才配搞怪的图，排完程配「开工」那张也合适。平均三四轮给一张，一次一张，别连着给。报错、追问、没听懂的回复一律不配图。
【看图片】他也会发图：课表、日程截图、待办清单、聊天记录、随手拍的东西。你**真的看得到图**，先看清上面写了什么再回话：课表就照图里的星期和时间排，截图里的事就按上面说的办；图里有关键信息就用图里的，别用自己脑补的替。看不清或字太小就直说「这块太糊了，看不清」，**不许猜着编内容**。看图回复也算干活那条，reply 收在 50 字内。

【怎么做事】
- 指令能看懂就直接给出动作（drafts），并用一句话说明结果，例如「已排 11:10–12:00 做时间表开发，还差约 10 分钟的量。」reply 一般不超过 40 字。
- 他让你排、挪、撤、开始、结束、记结果时，**必须**给出 drafts；只回「收到」「好的」这类空话等于没干活。一句话里有几件事，就拆成几个 draft 分开做，别都塞进同一个 draft。
- 缺的信息能合理推断就用默认值，不要追问：时长默认 60 分钟；没说结果标准时，outcome_criteria 写「完成：标题」；「现在/马上/这就」写 start_local "now"；只说「上午/下午/晚上」就挑该时段第一个空档。
- 只有在无法推断、而且猜错代价大时才追问，一次只问一个短问题，不给选择题，不要说「你定」。
- 估时只是参考：截止前时间不够，就把截止前能用的时间排满，用半句话说还差多少；不降低验收标准，不把估时当成不安排的理由。
- 「取消/删掉/关了/不要了」某段安排用 cancel_block；整件事不做了用 cancel_task。「推迟/挪到」用 move_block，要改时长就带 minutes。
- 用户说正在做的事做完了、要续时、要暂停，用 control_session / feedback；完成情况以用户的话为准，不替他宣布完成。这段在电脑上没点过开始、没有执行记录时，照样用 feedback 记结果（done / interrupted / partial / not_started），系统会把这段安排直接结掉；control_session 只用于已经开始的段。
- 过去的时间不能新排；用户补充过去发生的事，用 feedback 记录。不要把过去的时刻偷偷改成明天。
- 只安排在作息范围内，不与已有安排、固定预约(fixed)和保护时段(protected)重叠；任务已有未来安排时优先改期而不是重复创建。
- 只用名称称呼任务和安排，绝不向用户展示 t1、b2、c1 这类编号。

【记忆】分三层，别混：
- 长期偏好：上下文里「用户明确保存的偏好」是长期记忆，安排时要遵守（比如「上午做实验」就优先排上午）。
- 今天的事实：以当前日程、执行记录、结果检查点为准；他做了但没记录的，**不等于没做**，不许断言「你还没做」，也不许把上午的事当成刚发生。
- 刚才的对话：历史消息前面带 [时:分]。超过 45 分钟的旧话题不接着聊，他说新事就从新事开始。
- 用户在对话中说出关于自己的长期习惯或偏好（作息、擅长的时段、固定安排、称呼、做事方式），把它写成一句话放进 remember，最多 2 条；一次性的安排、情绪、闲聊不要记。
- 事实以当前日程、执行记录和带出处的回顾/材料为准，不从闲聊猜测用户特征。

只输出一个 JSON 对象：
{"reply": "给用户看的一句话", "drafts": [{"summary": "这组变化的一句话说明", "actions": [动作...]}], "remember": [], "meme": ""}
meme 只想发表情包时才填，取值只能用下面这些（类别=什么时候用）：__MEMES__。其余一律空字符串。
动作只能是以下几种（时间一律用用户时区的 "YYYY-MM-DD HH:MM"，或 "now"）：
{"type":"schedule_new","title":"...","outcome_criteria":"...","project":"c1（分类编号，可省略）","start_local":"...","until_local":"截止时刻，可省略","minutes":60,"kind":"flexible|fixed"}  新建一件事并排上
{"type":"schedule_task","task":"t1","start_local":"...","until_local":"可省略","minutes":60}   为已有任务排一段
{"type":"protect","title":"午饭","start_local":"...","minutes":45}       吃饭、休息等保护时段
{"type":"move_block","block":"b2","start_local":"...","minutes":90}     改期；minutes 省略则时长不变
{"type":"cancel_block","block":"b2"}                                     撤下一段尚未开始的安排
{"type":"cancel_task","task":"t1"}                                       整件事不做了（连同未来安排）
{"type":"control_session","block":"b1","action":"start|pause|resume|end|extend","minutes":15} 开始、暂停、恢复、结束或续时；minutes 只在 extend 必填。结束不等于完成，之后仍需反馈。
{"type":"feedback","block":"b2","choice":"done|partial|waiting|interrupted|not_started","outcome_text":"...","remaining_minutes":30,"check_local":"..."}
  partial 和 interrupted 需要 remaining_minutes；waiting 需要 check_local。
{"type":"snooze_waiting","waiting":"w1","check_local":"..."} 等待的结果还没回来，改约同一个检查点。
{"type":"resolve_waiting","waiting":"w1","resolution":"done|ready","remaining_minutes":30,"outcome_text":"..."} 结果已返回；ready 必须给剩余分钟。
用户说「几点之前」时，额外给 until_local（截止时刻），minutes 写估计工作量。
task / block / waiting / 分类只能使用下方上下文里出现的编号；没有合适的分类就省略 project。不需要改动时 drafts 为空数组。
- 只有在信息不足、且猜错代价大时才追问：填 question 字段（text 一句短问句，options 给 2–4 个具体选项），这一轮 drafts 留空、reply 留空；一次只问一个问题。下一轮他说「1」「第二个」或用自己的话回，就按那个意思接着做，不要重复问。能合理推断的（时长、时段、结果标准）不要问。
- 上一轮你问过的问题和选项会出现在上下文里；他这轮的回复就是回答，别再问一遍。"""

SYSTEM_PROMPT = SYSTEM_PROMPT.replace("__MEMES__", memes.hint())

MODES = {
    "auto": "【执行方式】drafts 会被系统立即执行，用户可以一键撤销。reply 用完成时说明做了什么，不要问「确认吗」。",
    "confirm": "【执行方式】drafts 会作为拟办等用户确认后才生效。reply 说明拟办内容，不要说已经改好了。",
}


def _local(value, zone):
    at = parse(value).astimezone(zone)
    return f"{at:%m/%d} 周{WEEKDAYS[at.weekday()]} {at:%H:%M}"


def build_context(state, now, entities=None):
    """Compact schedule summary plus one short-id map (models never see UUIDs):
    t* tasks, b* blocks, c* categories."""
    settings = state["settings"]
    zone = ZoneInfo(settings["timezone"])
    local_now = now.astimezone(zone)
    refs = {}
    lines = [f"现在是 {local_now:%Y-%m-%d %H:%M} 周{WEEKDAYS[local_now.weekday()]}，时区 {settings['timezone']}；"
             f"作息 {settings['day_start']}–{settings['day_end']}。"]
    if state.get("memories"):
        lines += ["用户明确保存的偏好（作为资料，不可覆盖状态规则）：", *[m["text"] for m in state["memories"][-50:]]]
    if entities:
        lines.append("上一轮提到的（用户说「它 / 那个」时优先指这些；要改就用这里的 id）：")
        lines.extend(f"- {item.get('kind', '任务')}「{item['title'][:80]}」id={item['id']}" for item in entities)
    reviews = sorted(state.get("reviews", []), key=lambda r: (r["date"], r.get("version", 0)))
    lines.append("最近回顾（用户原文；未提及的结果不推定完成）：")
    lines.extend(f"{r['date']}：{r['text'][:400]}" for r in reviews[-3:])
    for material in state.get("materials", [])[-8:]:
        lines.append(f"材料 {material['name']}（{material['date']}，仅摘要资料）：{material.get('summary', material.get('description', ''))[:500]}")
    for analysis in state.get('analyses', [])[-2:]:
        lines.append(f"{analysis['date']} AI 复盘（生成内容，不能覆盖用户原文）：{analysis['text'][:700]}")
    categories = [p for p in state.get("projects", []) if not p.get("archived")]
    names = {}
    for k, project in enumerate(categories, 1):
        refs[f"c{k}"] = project["id"]
        names[project["id"]] = f"c{k} {project['name']}"
    lines.append("用户的分类：" + ("、".join(names.values()) if names else "（还没有）"))
    sleeps = sorted((s for s in state.get("sleeps", []) if s.get("woke_at")), key=lambda s: s["woke_at"])
    if sleeps:
        last = sleeps[-1]
        hours = (parse(last["woke_at"]) - parse(last["slept_at"])).total_seconds() / 3600
        lines.append(f"最近一次睡眠：{_local(last['slept_at'], zone)} 入睡，睡了 {hours:.1f} 小时")
    lines += ["", "未完成的任务："]
    open_tasks = [t for t in state["tasks"] if t["state"] not in ("done", "cancelled")]
    for i, task in enumerate(open_tasks[-40:], 1):
        refs[f"t{i}"] = task["id"]
        deadline = f"，截止 {_local(task['deadline'], zone)}" if task.get("deadline") else ""
        category = names.get(task.get("project_id"), "未分类")
        lines.append(f"t{i}｜{task['title']}｜结果：{task['outcome_criteria']}｜{category}｜"
                     f"剩余 {task['remaining_minutes']} 分｜{task['state']}{deadline}")
    if not open_tasks:
        lines.append("（无）")
    midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    start, end = midnight - timedelta(days=1), midnight + timedelta(days=8)
    sessions = {s["block_id"]: s for s in state["sessions"]}
    today = [b for b in state["blocks"] if midnight <= parse(b["start_at"]) < midnight + timedelta(days=1)
             and b["status"] in ("scheduled", "completed", "skipped")]
    finished = [b for b in today if b["status"] == "completed"]
    active = [b for b in today if sessions.get(b["id"], {}).get("state") in ("running", "paused", "awaiting_feedback")]
    unrecorded = [b for b in today if b["status"] == "scheduled" and parse(b["end_at"]) <= now
                  and b["id"] not in sessions]
    progress = (f"今天的进度：{len(today)} 段安排，已完成 {len(finished)} 段，"
                f"正在做或等反馈 {len(active)} 段，过了点也没有任何记录的 {len(unrecorded)} 段")
    if unrecorded:
        progress += "（" + "、".join(b["title"] for b in unrecorded[:4]) + "）"
    lines.append(progress)
    shown = sorted((b for b in state["blocks"] if b["status"] in ("scheduled", "completed", "skipped")
                    and start <= parse(b["start_at"]) < end), key=lambda b: b["start_at"])
    lines += ["", "近期时间块（昨天到未来一周）："]
    for j, block in enumerate(shown[-80:], 1):
        refs[f"b{j}"] = block["id"]
        session = sessions.get(block["id"])
        run = f"，执行：{session['state']}，预计结束 {_local(session['expected_end_at'], zone)}" if session else ""
        if not session and block["status"] == "scheduled" and parse(block["end_at"]) <= now:
            run = "，过了点没记录（可能做了也可能没做，别当没发生）"
        lines.append(f"b{j}｜{_local(block['start_at'], zone)}–{parse(block['end_at']).astimezone(zone):%H:%M}｜"
                     f"{block['title']}｜{block['kind']}｜{block['status']}{run}")
    if not shown:
        lines.append("（无）")
    lines.append('未解决的结果检查点：')
    for i, check in enumerate((w for w in state.get('waiting_checks', []) if not w.get('resolved_at')), 1):
        refs[f'w{i}'] = check['id']
        task = next((t for t in state['tasks'] if t['id'] == check['task_id']), {})
        lines.append(f"w{i}｜{task.get('title', '等待事项')}｜检查 {_local(check['check_at'], zone)}")
    return "\n".join(lines), refs


def to_utc(text, zone):
    try:
        if len((text or '').strip()) < 16:
            raise ValueError('incomplete date and time')
        parsed = datetime.fromisoformat((text or '').strip())
    except ValueError:
        raise DomainError(f"时间格式不对：{text}", "DRAFT_INVALID", 422) from None
    naive = parsed.replace(tzinfo=None)
    if parsed.tzinfo is not None:
        if parsed.astimezone(zone).replace(tzinfo=None) != naive:
            raise DomainError('给定的时区偏移与当地时刻不匹配', 'DRAFT_INVALID', 422)
        return parsed.astimezone(timezone.utc)
    aware = naive.replace(tzinfo=zone)
    if aware.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) != naive:
        raise DomainError("这个本地时间因夏令时切换不存在", "DRAFT_INVALID", 422)
    if naive.replace(tzinfo=zone, fold=1).utcoffset() != aware.utcoffset():
        raise DomainError('这个本地时间出现两次，请说明第一次还是第二次，并明确时区偏移', 'DRAFT_INVALID', 422)
    return aware.astimezone(timezone.utc)


def parse_reply(raw):
    text = raw.strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text[text.index("{"):] if "{" in text else text
    if "{" in text and "}" in text:
        text = text[text.index("{"): text.rindex("}") + 1]
    return ModelReply.model_validate(json.loads(text))


def visible_text(text, state, refs):
    titles = {v['id']: v['title'] for group in (state.get('tasks', []), state.get('blocks', [])) for v in group}
    for short, real_id in refs.items():
        if real_id in titles:
            text = re.sub(r'(?<![a-zA-Z0-9])' + re.escape(short) + r'(?![a-zA-Z0-9])', lambda _: titles[real_id], text)
    return text


def resolve_drafts(reply, state, refs, now, requested_at=None):
    """Map short ids to real ids and wall times to UTC; keep the actions that make sense."""
    zone = ZoneInfo(state["settings"]["timezone"])
    resolved, notes = [], []
    for draft in reply.drafts:
        actions = []
        for action in draft.actions:
            try:
                actions.append(resolve_action(action, state, refs, now, requested_at, zone))
            except DomainError as error:
                notes.append(note_for(error))
        if actions:  # one bad action must not throw away the rest of the same message
            resolved.append({"summary": visible_text(draft.summary, state, refs), "actions": actions})
    return resolved, notes


def note_for(error):
    if error.code == 'DRAFT_PAST':
        return '这个时刻已经过去了：要补记结果，还是重新安排？'
    if '不存在' in error.message:
        return '对应任务或安排不存在，请明确任务名称。'
    return error.message


def resolve_action(action, state, refs, now, requested_at, zone):
    """Resolve one draft action against the current state, or raise DomainError."""
    item = action.model_dump()
    if item['type'] in ('snooze_waiting', 'resolve_waiting'):
        short = item.pop('waiting')
        check = next((c for c in state['waiting_checks'] if c['id'] == refs.get(short) and not c.get('resolved_at')), None)
        if not short.startswith('w') or check is None:
            raise DomainError('等待检查点不存在或已处理')
        item['check_id'], item['check_version'] = check['id'], check.get('version', 1)
    for short, field, label in (("task", "task_id", "任务"), ("block", "block_id", "时间块")):
        if short in item:
            ref = item.pop(short)
            if not ref.startswith(short[0]) or ref not in refs:
                raise DomainError(f"引用了不存在的{label} {ref}", "DRAFT_INVALID", 422)
            item[field] = refs[ref]
            collection = state['tasks'] if field == 'task_id' else state['blocks']
            entity = next((v for v in collection if v['id'] == refs[ref]), None)
            if entity is None:
                raise DomainError(f'对应{label}不存在')
            item[f'{short}_version'] = entity['version']
    if "project" in item:
        ref = item.pop("project")
        item["project_id"] = refs.get(ref) if ref and ref.startswith("c") else None
    for field, target in (("start_local", "start_at"), ("check_local", "check_at")):
        if item.get(field):
            raw_at = item.pop(field)
            immediate = field == "start_local" and raw_at.lower() in ("now", "现在", "马上")
            at = now + timedelta(seconds=5) if immediate else to_utc(raw_at, zone)
            # A minute-precision model answer may refer to the current minute.
            if field == "start_local" and (now.replace(second=0, microsecond=0) == at or
                (requested_at and requested_at.replace(second=0, microsecond=0) == at and now - requested_at <= timedelta(minutes=2))):
                immediate = True
                at = now + timedelta(seconds=5)
            if at <= now:
                raise DomainError("建议的时间已经过去", "DRAFT_PAST", 422)
            item[target] = stamp(at)
            if immediate and item["type"] in ("schedule_new", "schedule_task"):
                item["start_mode"] = "now"
        else:
            item.pop(field, None)
    if item['type'] == 'control_session' and item['action'] != 'start':
        session = next((s for s in reversed(state['sessions']) if s['block_id'] == item['block_id']), None)
        if session is None:
            raise DomainError('这段还没有开始过，直接说「做完了/被打断/没开始」我来记结果')
        item['session_id'], item['session_version'] = session['id'], session['version']
        if item['action'] == 'extend' and not item.get('minutes'):
            raise DomainError('请说明要续时几分钟')
    until = item.pop("until_local", None)
    if until:
        item["until_at"] = stamp(to_utc(until, zone))
        capacity = (parse(item["until_at"]) - parse(item["start_at"])).total_seconds()
        item["minutes"] = min(item["minutes"], math.ceil(capacity / 60))
        if capacity < 300 or item["minutes"] < 5:
            raise DomainError("截止前不足 5 分钟，请选择稍后的时段", "DRAFT_PAST", 422)
    item["label"] = describe(item, state, zone)
    return item


def when_block(block, zone):
    if "start_at" not in block:
        return ""
    at, end = parse(block["start_at"]).astimezone(zone), parse(block["end_at"]).astimezone(zone)
    return f"{at:%m/%d} 周{WEEKDAYS[at.weekday()]} {at:%H:%M}–{end:%H:%M}"


def describe(item, state, zone):
    def when(key, minutes=None):
        at = parse(item[key]).astimezone(zone)
        tail = f"–{(at + timedelta(minutes=minutes)):%H:%M}" if minutes else ""
        return f"{at:%m/%d} 周{WEEKDAYS[at.weekday()]} {at:%H:%M}{tail}"

    kind = item["type"]
    if kind == 'snooze_waiting':
        return f"改约结果检查 · {when('check_at')}"
    if kind == 'resolve_waiting':
        return '结果已返回 · 确认完成' if item['resolution'] == 'done' else f"结果已返回 · 还需 {item.get('remaining_minutes') or '待确认'} 分钟"
    if kind == 'control_session':
        title = next((b['title'] for b in state['blocks'] if b['id'] == item['block_id']), '当前安排')
        label = {'start': '开始', 'pause': '暂停', 'resume': '继续', 'end': '结束并等待反馈', 'extend': '续时'}[item['action']]
        return f"{label} · {title}" + (f" +{item['minutes']} 分钟" if item['action'] == 'extend' else '')
    if kind == "schedule_new":
        return f"新增 · {when('start_at', item['minutes'])} {item['title']}"
    if kind == "schedule_task":
        title = next((t["title"] for t in state["tasks"] if t["id"] == item["task_id"]), "任务")
        return f"再安排 · {when('start_at', item['minutes'])} {title}"
    if kind == "protect":
        return f"留白 · {when('start_at', item['minutes'])} {item['title']}"
    if kind == "cancel_task":
        title = next((t["title"] for t in state["tasks"] if t["id"] == item["task_id"]), "任务")
        return f"不做了 · {title}（未来安排一并撤下）"
    block = next((b for b in state["blocks"] if b["id"] == item["block_id"]), {"title": "时间块"})
    if kind == "move_block":
        return f"改期 · {block['title']} → {when('start_at', item.get('minutes'))}"
    if kind == "cancel_block":
        return f"撤下 · {when_block(block, zone)} {block['title']}"
    labels = {"done": "完成了", "partial": "部分完成", "waiting": "等待结果", "interrupted": "被打断", "not_started": "没有开始"}
    return f"记录 · {block['title']}：{labels[item['choice']]}"


def draft_operations(state, actions, now):
    """Translate confirmed draft actions into ordinary operations."""
    zone_name = state["settings"]["timezone"]
    operations = []

    def future(at):
        if parse(at) <= now:
            raise DomainError("拟办里的时间已经过去了，请再问一次助手", "DRAFT_PAST", 409)
        return at

    for item in actions:
        kind = item["type"]
        for field, collection in (('task', 'tasks'), ('block', 'blocks')):
            if f'{field}_version' in item:
                entity = next((v for v in state[collection] if v['id'] == item[f'{field}_id']), None)
                if entity is None or entity['version'] != item[f'{field}_version']:
                    raise DomainError('任务或安排已变化，请按当前状态重新生成', 'STALE_VERSION')
        if kind == 'snooze_waiting':
            operations.append(('waiting.snooze', {'id': item['check_id'], 'version': item['check_version'], 'check_at': future(item['check_at'])}))
        elif kind == 'resolve_waiting':
            payload = {'id': item['check_id'], 'resolution': item['resolution'], 'outcome_text': item['outcome_text']}
            if item.get('remaining_minutes') is not None:
                payload['remaining_minutes'] = item['remaining_minutes']
            operations.append(('waiting.resolve', payload))
        elif kind == 'control_session':
            if item['action'] == 'start':
                operations.append(('session.start', {'id': identifier(), 'block_id': item['block_id']}))
            else:
                session = next((s for s in state['sessions'] if s['id'] == item['session_id']), None)
                if not session or session['version'] != item['session_version']:
                    raise DomainError('执行状态已变化，请重新确认', 'STALE_VERSION')
                payload = {'id': session['id']}
                if item['action'] == 'extend':
                    payload['minutes'] = item['minutes']
                operations.append((f"session.{item['action']}", payload))
        elif kind in ("schedule_new", "schedule_task", "protect"):
            start = now + timedelta(seconds=5) if item.get("start_mode") == "now" else parse(future(item["start_at"]))
            end_at = start + timedelta(minutes=item["minutes"])
            if item.get("until_at"):
                end_at = min(end_at, parse(item["until_at"]))
            if end_at - start < timedelta(minutes=5):
                raise DomainError("截止前不足 5 分钟，请重新安排", "DRAFT_PAST", 409)
            end = stamp(end_at)
            task_id = item.get("task_id")
            if kind == "schedule_new":
                task_id = identifier()
                operations.append(("task.create", {"id": task_id, "title": item["title"],
                                                   "outcome_criteria": item["outcome_criteria"],
                                                   "project_id": item.get("project_id"), "remaining_minutes": item["minutes"]}))
            operations.append(("block.create", {"id": identifier(), "task_id": task_id if kind != "protect" else None,
                                                "title": item["title"] if kind == "protect" else "安排",
                                                "start_at": stamp(start), "end_at": end, "timezone": zone_name,
                                                "kind": "protected" if kind == "protect" else item.get("kind", "flexible")}))
        elif kind == "move_block":
            block = find(state, "blocks", item["block_id"])
            start = parse(future(item["start_at"]))
            length = (timedelta(minutes=item["minutes"]) if item.get("minutes")
                      else parse(block["end_at"]) - parse(block["start_at"]))
            # The user named this block, so moving their own fixed or protected time is intended.
            operations.append(("block.move", {"id": block["id"], "version": block["version"],
                                              "start_at": stamp(start), "end_at": stamp(start + length),
                                              "allow_fixed": True}))
        elif kind == "cancel_block":
            block = find(state, "blocks", item["block_id"])
            operations.append(("block.cancel", {"id": block["id"], "version": block["version"]}))
        elif kind == "cancel_task":
            task = find(state, "tasks", item["task_id"])
            operations.append(("task.update", {"id": task["id"], "version": task["version"], "state": "cancelled"}))
        elif kind == "feedback":
            block = find(state, "blocks", item["block_id"])
            session = next((s for s in state["sessions"] if s["block_id"] == block["id"]), None)
            payload = {"choice": item["choice"], "outcome_text": item.get("outcome_text", "")}
            if item.get("remaining_minutes"):
                payload["remaining_minutes"] = item["remaining_minutes"]
            if item.get("check_at"):
                payload["check_at"] = future(item["check_at"])
            if session and session["state"] == "awaiting_feedback":
                payload["session_id"] = session["id"]
            elif session:
                raise DomainError(f"「{block['title']}」这段还没结束，先结束再记结果", "DRAFT_STALE", 409)
            elif block["status"] == "scheduled":
                # Remote channels (QQ / WeChat) often never see a start press; still record the result.
                payload["block_id"] = block["id"]
            else:
                raise DomainError(f"「{block['title']}」这段已经记录过结果了", "DRAFT_STALE", 409)
            operations.append(("feedback.create", payload))
    return operations


def usage_today(conn, now, user_id):
    row = conn.execute("SELECT calls FROM assistant_usage_by_user WHERE user_id=? AND day=?",
                       (user_id, now.date().isoformat())).fetchone()
    return row["calls"] if row else 0


def count_call(conn, now, calls=1, *, user_id):
    conn.execute(
        "INSERT INTO assistant_usage_by_user(user_id, day, calls) VALUES(?,?,?)"
        " ON CONFLICT(user_id, day) DO UPDATE SET calls=calls+?",
        (user_id, now.date().isoformat(), calls, calls),
    )


def message_rows(conn, limit=60, user_id=""):
    rows = conn.execute(
        "SELECT * FROM assistant_messages WHERE user_id=? ORDER BY created_at DESC, rowid DESC LIMIT ?",
        (user_id, limit),
    ).fetchall()
    result = []
    for row in reversed(rows):
        drafts = conn.execute("SELECT d.*, u.draft_id AS undo FROM assistant_drafts d LEFT JOIN assistant_undo u "
                              "ON u.draft_id=d.id WHERE d.message_id=? ORDER BY d.rowid", (row["id"],)).fetchall()
        meme = conn.execute("SELECT name FROM assistant_memes WHERE message_id=?", (row["id"],)).fetchone()
        result.append({**dict(row), "meme": meme["name"] if meme else "",
                       "drafts": [public_draft(d, d["status"] == "applied" and d["undo"] is not None)
                                  for d in drafts]})
    return result


def public_draft(row, undoable=False):
    actions = json.loads(row["actions"])
    return {"id": row["id"], "summary": row["summary"], "status": row["status"],
            "lines": [a["label"] for a in actions], "undoable": undoable}
