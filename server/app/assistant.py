"""OpenAI-compatible assistant: local configuration, chat, and drafts that
only change the schedule after the user confirms them.

The API key never leaves this computer: it is read from PLANNER_LLM_API_KEY or
<data>/secrets/llm-key and is never returned by any endpoint.
"""
import asyncio
import json
import os
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal, Union
from zoneinfo import ZoneInfo

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from .domain import DomainError, find, identifier, parse, stamp

SCHEMA = """
CREATE TABLE IF NOT EXISTS assistant_messages (id TEXT PRIMARY KEY, role TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS assistant_drafts (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, summary TEXT NOT NULL, actions TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS assistant_usage (day TEXT PRIMARY KEY, calls INTEGER NOT NULL);
"""

RETRY_DELAYS = (0, 1.5, 4.0)
WEEKDAYS = "一二三四五六日"
DEFAULTS = {"base_url": "", "model": "", "daily_limit": 200, "timeout_seconds": 45}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class AssistantConfigIn(Strict):
    base_url: str | None = Field(default=None, max_length=300)
    model: str | None = Field(default=None, max_length=120)
    api_key: str | None = Field(default=None, max_length=400)
    clear_key: bool = False
    daily_limit: int | None = Field(default=None, ge=1, le=5000)

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
                "key_source": source, "key_hint": ("····" + key[-4:]) if len(key) >= 8 else ("已设置" if key else "")}

    def update(self, data: AssistantConfigIn):
        conf = self.load()
        for field in ("base_url", "model", "daily_limit"):
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
    problem = "模型服务暂时不可用"
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
                return response.json()["choices"][0]["message"]["content"] or ""
            except (ValueError, KeyError, IndexError, TypeError):
                sample = response.text[:80].replace(key, "****") if key else response.text[:80]
                raise DomainError(f"模型服务的回复不是 OpenAI 兼容格式，收到：{sample}", "LLM_FORMAT", 502) from None
    raise DomainError(problem, "LLM_UNAVAILABLE", 502)


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
    minutes: int = Field(ge=5, le=600)
    kind: Literal["flexible", "fixed"] = "flexible"


class ScheduleTask(Loose):
    type: Literal["schedule_task"]
    task: str
    start_local: str
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


class Feedback(Loose):
    type: Literal["feedback"]
    block: str
    choice: Literal["done", "partial", "waiting", "interrupted", "not_started"]
    outcome_text: str = Field(default="", max_length=4000)
    remaining_minutes: int | None = Field(default=None, ge=1, le=100000)
    check_local: str | None = None


Action = Annotated[Union[ScheduleNew, ScheduleTask, Protect, MoveBlock, Feedback], Field(discriminator="type")]


class DraftOut(Loose):
    summary: str = Field(min_length=1, max_length=200)
    actions: list[Action] = Field(min_length=1, max_length=12)


class ModelReply(Loose):
    reply: str = Field(default="", max_length=3000)
    drafts: list[DraftOut] = Field(default_factory=list, max_length=5)


SYSTEM_PROMPT = """你是用户的私人时间管理助手，帮他把每天的时间安排得有结果、有弹性。
原则：
- 每件事都要有可检验的结果（outcome_criteria）；用户没说清楚时，先追问一句，不要替他编造。
- 只安排在作息范围内，不要占用固定预约(fixed)和保护时段(protected)，不要与已有安排重叠，给休息留空。
- 不能安排已经过去的时间。
- 用户描述迟到、没做完、在等结果等变化时，先确认事实，再提出调整。
- 你不能直接修改日程。需要修改时，在 drafts 里给出「拟办」，用户确认后才会生效。绝不说"已经帮你改好了"。
- 语气平静、温和、简短，不说教、不鸡汤、不用 emoji。reply 不超过 150 字。
只输出一个 JSON 对象，格式：
{"reply": "给用户看的话", "drafts": [{"summary": "一句话说明这组变化", "actions": [动作...]}]}
动作只能是以下几种（时间一律用用户时区的 "YYYY-MM-DD HH:MM"）：
{"type":"schedule_new","title":"...","outcome_criteria":"...","project":"c1（分类编号，可省略）","start_local":"...","minutes":60,"kind":"flexible|fixed"}
{"type":"schedule_task","task":"t1","start_local":"...","minutes":60}   为已有任务再安排一段
{"type":"protect","title":"午饭","start_local":"...","minutes":45}       吃饭、休息等保护时段
{"type":"move_block","block":"b2","start_local":"..."}                 改期，时长不变
{"type":"feedback","block":"b2","choice":"done|partial|waiting|interrupted|not_started","outcome_text":"...","remaining_minutes":30,"check_local":"..."}
  partial 和 interrupted 需要 remaining_minutes；waiting 需要 check_local。
task / block / 分类只能使用下方上下文里出现的编号；没有合适的分类就省略 project。不需要改动时 drafts 为空数组。"""


def _local(value, zone):
    at = parse(value).astimezone(zone)
    return f"{at:%m/%d} 周{WEEKDAYS[at.weekday()]} {at:%H:%M}"


def build_context(state, now):
    """Compact schedule summary plus one short-id map (models never see UUIDs):
    t* tasks, b* blocks, c* categories."""
    settings = state["settings"]
    zone = ZoneInfo(settings["timezone"])
    local_now = now.astimezone(zone)
    refs = {}
    lines = [f"现在是 {local_now:%Y-%m-%d %H:%M} 周{WEEKDAYS[local_now.weekday()]}，时区 {settings['timezone']}；"
             f"作息 {settings['day_start']}–{settings['day_end']}。"]
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
    shown = sorted((b for b in state["blocks"] if b["status"] in ("scheduled", "completed", "skipped")
                    and start <= parse(b["start_at"]) < end), key=lambda b: b["start_at"])
    lines += ["", "近期时间块（昨天到未来一周）："]
    for j, block in enumerate(shown[-80:], 1):
        refs[f"b{j}"] = block["id"]
        session = sessions.get(block["id"])
        run = f"，执行：{session['state']}" if session else ""
        lines.append(f"b{j}｜{_local(block['start_at'], zone)}–{parse(block['end_at']).astimezone(zone):%H:%M}｜"
                     f"{block['title']}｜{block['kind']}｜{block['status']}{run}")
    if not shown:
        lines.append("（无）")
    return "\n".join(lines), refs


def to_utc(text, zone):
    try:
        naive = datetime.strptime((text or "").strip(), "%Y-%m-%d %H:%M")
    except ValueError:
        raise DomainError(f"时间格式不对：{text}", "DRAFT_INVALID", 422) from None
    aware = naive.replace(tzinfo=zone)
    if aware.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) != naive:
        raise DomainError("这个本地时间因夏令时切换不存在", "DRAFT_INVALID", 422)
    return aware.astimezone(timezone.utc)


def parse_reply(raw):
    text = raw.strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text[text.index("{"):] if "{" in text else text
    if "{" in text and "}" in text:
        text = text[text.index("{"): text.rindex("}") + 1]
    return ModelReply.model_validate(json.loads(text))


def resolve_drafts(reply, state, refs, now):
    """Map short ids to real ids and wall times to UTC; drop unusable drafts."""
    zone = ZoneInfo(state["settings"]["timezone"])
    resolved, notes = [], []
    for draft in reply.drafts:
        try:
            actions = []
            for action in draft.actions:
                item = action.model_dump()
                for short, field, label in (("task", "task_id", "任务"), ("block", "block_id", "时间块")):
                    if short in item:
                        ref = item.pop(short)
                        if not ref.startswith(short[0]) or ref not in refs:
                            raise DomainError(f"引用了不存在的{label} {ref}", "DRAFT_INVALID", 422)
                        item[field] = refs[ref]
                if "project" in item:
                    ref = item.pop("project")
                    item["project_id"] = refs.get(ref) if ref and ref.startswith("c") else None
                for field, target in (("start_local", "start_at"), ("check_local", "check_at")):
                    if item.get(field):
                        at = to_utc(item.pop(field), zone)
                        if at <= now:
                            raise DomainError("建议的时间已经过去", "DRAFT_PAST", 422)
                        item[target] = stamp(at)
                    else:
                        item.pop(field, None)
                item["label"] = describe(item, state, zone)
                actions.append(item)
            resolved.append({"summary": draft.summary, "actions": actions})
        except DomainError as error:
            notes.append(f"「{draft.summary}」未能整理成可执行的安排（{error.message}）")
    return resolved, notes


def describe(item, state, zone):
    def when(key, minutes=None):
        at = parse(item[key]).astimezone(zone)
        tail = f"–{(at + timedelta(minutes=minutes)):%H:%M}" if minutes else ""
        return f"{at:%m/%d} 周{WEEKDAYS[at.weekday()]} {at:%H:%M}{tail}"

    kind = item["type"]
    if kind == "schedule_new":
        return f"新增 · {when('start_at', item['minutes'])} {item['title']}"
    if kind == "schedule_task":
        title = next((t["title"] for t in state["tasks"] if t["id"] == item["task_id"]), "任务")
        return f"再安排 · {when('start_at', item['minutes'])} {title}"
    if kind == "protect":
        return f"留白 · {when('start_at', item['minutes'])} {item['title']}"
    block = next((b for b in state["blocks"] if b["id"] == item["block_id"]), {"title": "时间块"})
    if kind == "move_block":
        return f"改期 · {block['title']} → {when('start_at')}"
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
        if kind in ("schedule_new", "schedule_task", "protect"):
            start = parse(future(item["start_at"]))
            end = stamp(start + timedelta(minutes=item["minutes"]))
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
            length = parse(block["end_at"]) - parse(block["start_at"])
            operations.append(("block.move", {"id": block["id"], "version": block["version"],
                                              "start_at": stamp(start), "end_at": stamp(start + length)}))
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
            elif item["choice"] == "not_started" and not session:
                payload["block_id"] = block["id"]
            else:
                raise DomainError(f"「{block['title']}」还没有可以反馈的执行记录", "DRAFT_STALE", 409)
            operations.append(("feedback.create", payload))
    return operations


def usage_today(conn, now):
    row = conn.execute("SELECT calls FROM assistant_usage WHERE day=?", (now.date().isoformat(),)).fetchone()
    return row["calls"] if row else 0


def count_call(conn, now, calls=1):
    conn.execute("INSERT INTO assistant_usage VALUES(?,?) ON CONFLICT(day) DO UPDATE SET calls=calls+?",
                 (now.date().isoformat(), calls, calls))


def message_rows(conn, limit=60):
    rows = conn.execute("SELECT * FROM assistant_messages ORDER BY created_at DESC, rowid DESC LIMIT ?", (limit,)).fetchall()
    result = []
    for row in reversed(rows):
        drafts = conn.execute("SELECT * FROM assistant_drafts WHERE message_id=? ORDER BY rowid", (row["id"],)).fetchall()
        result.append({**dict(row), "drafts": [public_draft(d) for d in drafts]})
    return result


def public_draft(row):
    actions = json.loads(row["actions"])
    return {"id": row["id"], "summary": row["summary"], "status": row["status"],
            "lines": [a["label"] for a in actions]}
