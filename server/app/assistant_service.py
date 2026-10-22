"""Assistant conversation and draft confirmation shared by the app API and WeChat."""
import base64
import json
import time
import re
from copy import deepcopy
from datetime import timedelta
from uuid import uuid5, NAMESPACE_URL
from zoneinfo import ZoneInfo

from pydantic import ValidationError

from . import assistant, timings
from .domain import DomainError, apply, identifier, stamp, parse
from .maintenance import expire_due
from .models import Operation
from .reports import flush_archives
from .store import digest, encode


UNDOABLE = {"schedule_new", "schedule_task", "protect", "move_block", "cancel_block", "cancel_task"}

MAX_REMEMBERED_PER_TURN = 2
MEMORY_LIMIT = 50


def memory_key(text):
    """Normalized identity of a memory: whitespace and punctuation don't spawn twins."""
    return re.sub(r"[\s。，、；：！？!?,.;:：（）()「」\"'“”‘’]", "", text or "").lower()


def undo_operations(before, after):
    """Operations that turn the schedule in `after` back into `before`.

    Only task and block changes are reversed; drafts that touch executions or
    feedback are never offered an undo."""
    old_tasks = {t["id"]: t for t in before["tasks"]}
    old_blocks = {b["id"]: b for b in before["blocks"]}
    new_tasks = {t["id"] for t in after["tasks"] if t["id"] not in old_tasks}
    reopen, restore, move, cancel, drop = [], [], [], [], []
    for task in after["tasks"]:
        if task["id"] in new_tasks:
            drop.append(("task.update", {"id": task["id"], "version": task["version"], "state": "cancelled"}))
        elif task["state"] == "cancelled" and old_tasks[task["id"]]["state"] != "cancelled":
            previous = old_tasks[task["id"]]["state"]
            reopen.append(("task.update", {"id": task["id"], "version": task["version"],
                                           "state": previous if previous in ("ready", "review") else "ready"}))
    for block in after["blocks"]:
        old = old_blocks.get(block["id"])
        if old is None:
            if block.get("task_id") not in new_tasks:
                cancel.append(("block.cancel", {"id": block["id"], "version": block["version"]}))
        elif old["status"] == "scheduled" and block["status"] == "cancelled":
            restore.append(("block.restore", {"id": block["id"], "version": block["version"]}))
        elif (old["start_at"], old["end_at"]) != (block["start_at"], block["end_at"]):
            move.append(("block.move", {"id": block["id"], "version": block["version"], "start_at": old["start_at"],
                                        "end_at": old["end_at"], "allow_fixed": True}))
    # Free the new slots first so moved and restored blocks can return to them.
    return cancel + drop + reopen + move + restore


def pending_question(conn, user_id, now):
    """The one question still waiting for an answer, if it has not expired."""
    return conn.execute(
        "SELECT id, text, options FROM assistant_pending_questions"
        " WHERE user_id=? AND answered_at IS NULL AND expires_at>?"
        " ORDER BY created_at DESC LIMIT 1", (user_id, stamp(now))).fetchone()


def close_pending_questions(conn, user_id, now):
    """A new user turn supersedes every question asked before it."""
    conn.execute("UPDATE assistant_pending_questions SET answered_at=?"
                 " WHERE user_id=? AND answered_at IS NULL", (stamp(now), user_id))


def ask_question(conn, user_id, now, question):
    """Store a question for ten minutes so the next turn can read the answer."""
    conn.execute("INSERT INTO assistant_pending_questions"
                 " (id, user_id, text, options, created_at, expires_at) VALUES(?,?,?,?,?,?)",
                 (identifier(), user_id, question.text[:200],
                  json.dumps(list(question.options)[:4], ensure_ascii=False),
                  stamp(now), stamp(now + timedelta(minutes=10))))


def recent_entities(conn, user_id, now, ttl_minutes=45):
    """What the last turn was about, so「它 / 那个」has a referent."""
    row = conn.execute("SELECT entities, updated_at FROM assistant_context WHERE user_id=?",
                       (user_id,)).fetchone()
    if not row or parse(row["updated_at"]) < now - timedelta(minutes=ttl_minutes):
        return []
    try:
        items = json.loads(row["entities"])
    except ValueError:
        return []
    return [item for item in items if isinstance(item, dict) and item.get("id") and item.get("title")]


def remember_entities(conn, user_id, items, now, limit=6):
    """Keep the newest few entities from this turn in front of the older ones."""
    items = [item for item in items if item.get("id") and item.get("title")]
    if not items:
        return
    merged = []
    for item in [*items, *recent_entities(conn, user_id, now)]:
        if all(existing["id"] != item["id"] for existing in merged):
            merged.append(item)
    conn.execute("INSERT OR REPLACE INTO assistant_context VALUES(?,?,?)",
                 (user_id, json.dumps(merged[:limit], ensure_ascii=False), stamp(now)))


MAX_AUTO_ACTIONS = 3  # auto mode only takes small steps on its own (plan §9.3)


def needs_confirm(draft, state, zone):
    """Big or cross-day edits wait for an explicit「确认」even in auto mode."""
    actions = draft.get("actions", [])
    if len(actions) > MAX_AUTO_ACTIONS:
        return True
    days = set()
    blocks = {block["id"]: block for block in state.get("blocks", [])}
    for action in actions:
        if action.get("type") not in ("schedule_new", "schedule_task", "protect", "move_block"):
            continue
        for key in ("start_at", "end_at"):
            if action.get(key):
                days.add(parse(action[key]).astimezone(zone).date())
        for key in ("block_id", "id"):
            block = blocks.get(action.get(key) or "")
            if block:
                days.add(parse(block["start_at"]).astimezone(zone).date())
    return len(days) > 1


def touched_entities(state, drafts):
    """Task/block titles a turn proposed or changed — what later「它」should point at."""
    tasks = {task["id"]: task for task in state.get("tasks", [])}
    blocks = {block["id"]: block for block in state.get("blocks", [])}
    items = []
    for draft in drafts:
        for action in draft.get("actions", []):
            kind = action.get("type", "")
            ids = [action.get(key) for key in ("task_id", "block_id", "id") if action.get(key)]
            for form, collection in (("任务", tasks), ("安排", blocks)):
                found = next((collection[item_id] for item_id in ids if item_id in collection), None)
                if found:
                    items.append({"kind": form, "id": found["id"], "title": found["title"]})
            if kind in ("schedule_new", "schedule_task", "protect") and action.get("title"):
                items.append({"kind": "安排", "id": action.get("task_id") or "", "title": action["title"]})
    return [item for item in items if item["id"]]


class AssistantService:
    def __init__(self, store, clock, transport=lambda: None):
        self.store, self.clock, self.transport = store, clock, transport
        self.configs = assistant.AssistantConfigStore(store)
        with store.connect() as conn:
            assistant.ensure_schema(conn, store.owner_id)

    def user(self, user_id):
        """Assistant calls that don't name a user belong to the owner (channels)."""
        return user_id or self.store.owner_id

    def require(self, conn, user_id=None):
        user_id = self.user(user_id)
        if not self.configs.configured(conn, user_id):
            raise DomainError("助手还没有配置：请在「设置 · 助手」填写服务地址、模型和你自己的 API Key",
                              "ASSISTANT_NOT_CONFIGURED", 409)
        conf = self.configs.load(conn, user_id)
        if assistant.usage_today(conn, self.clock(), user_id) >= conf["daily_limit"]:
            raise DomainError("今天的助手调用次数已用完，可在「设置 · 助手」调高上限", "ASSISTANT_LIMIT", 429)
        return conf, self.configs.key(conn, user_id)[0]

    def apply_operation(self, kind, payload, device_id="assistant", operation_id=None, user_id=None):
        user_id = self.user(user_id)
        operation = Operation(operation_id=operation_id or identifier(), kind=kind, payload=payload)
        request_hash = digest(encode(operation.model_dump()))
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            previous = conn.execute(
                "SELECT * FROM operations WHERE id=? AND (user_id=? OR user_id IS NULL)",
                (operation.operation_id, user_id),
            ).fetchone()
            if previous:
                if previous["request_hash"] != request_hash or previous["device_id"] != device_id:
                    raise DomainError("操作标识冲突")
                return json.loads(previous["response"])
            state = self.store.state(conn, user_id)
            entity = apply(state, operation, device_id, self.clock())
            state["revision"] += 1
            result = {"revision": state["revision"], "entity": entity, "operation_id": operation.operation_id}
            self.store.save(conn, state, user_id)
            conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, user_id, request_hash, encode(result)))
            self.store.record_event(conn, user_id, state["revision"], device_id, kind, payload, self.clock())
        flush_archives(self.store, self.clock())
        return result

    def _exchange(self, text, answer, user_id=None):
        user_id = self.user(user_id)
        now = self.clock()
        with self.store.connect() as conn:
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?,?)", (identifier(), "user", text, stamp(now), user_id))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?,?)", (identifier(), "assistant", answer, stamp(now + timedelta(microseconds=1)), user_id))
            return assistant.message_rows(conn, 2, user_id)

    async def converse(self, text, request_id=None, device_id="assistant", image=None, user_id=None):
        """One user turn. Returns the stored user + assistant rows (with drafts).

        ``image`` 是 (mime, bytes)：带上它就把图作为这一轮的用户消息一起发给模型看。
        """
        user_id = self.user(user_id)
        now = self.clock()
        expire_due(self.store, now, user_id)
        shown = f"[图片] {text}".strip() if image else text
        memory = re.fullmatch(r"(?:请)?记住[：:]\s*(.{1,1000})", text.strip(), re.S)
        forget = re.fullmatch(r"(?:请)?忘记[：:]\s*(.{1,1000})", text.strip(), re.S)
        if memory:
            memory_id = uuid5(NAMESPACE_URL, request_id).hex if request_id else identifier()
            self.apply_operation("memory.save", {"id": memory_id, "text": memory.group(1).strip()},
                                 operation_id=f'wechat-memory:{request_id}' if request_id else None,
                                 user_id=user_id)
            return self._exchange(text, "已记住。你可以在助手的「记忆」中查看或删除。", user_id)
        if forget:
            matches = [m for m in self.store.state(user_id=user_id).get("memories", []) if m["text"] == forget.group(1).strip()]
            for item in matches:
                self.apply_operation("memory.delete", {"id": item["id"]}, user_id=user_id)
            return self._exchange(text, "已删除这条记忆。" if matches else "没有找到这条记忆，可在助手的「记忆」中查看。", user_id)
        with self.store.connect() as conn:
            conf, key = self.require(conn, user_id)
            state = self.store.state(conn, user_id)
            history = conn.execute("SELECT role,text,created_at FROM assistant_messages WHERE user_id=? AND created_at>=? "
                                   "ORDER BY created_at DESC, rowid DESC LIMIT 10",
                                   (user_id, stamp(now - timedelta(minutes=45)))).fetchall()
            waiting_on = pending_question(conn, user_id, now)
            entities = recent_entities(conn, user_id, now)
        if image and not conf.get("vision"):
            return self._exchange(
                text,
                "这个模型看不了图（或者还没打开「能看图」）。把图里的关键内容打字发我，"
                "或者去「设置 · 助手」打开「这个模型能看图」再发一次。",
                user_id,
            )
        # Removing a memory must also keep the original memory command out of model context.
        history = [row for row in history if not (row['role'] == 'user' and re.match(r'^(?:请)?(?:记住|忘记)[：:]', row['text']))]
        context, refs = assistant.build_context(state, now, entities=entities)
        if waiting_on:
            options = json.loads(waiting_on["options"] or "[]")
            listed = " ".join(f"{index}. {option}" for index, option in enumerate(options, 1))
            context += ("\n【上一轮你问过的问题】" + waiting_on["text"]
                        + (f"；选项：{listed}" if listed else "")
                        + "。他这一轮的话很可能就是回答：按选项的意思接着做，不要重复问同一个问题。")
        mode = "confirm" if conf.get("confirm_first") else "auto"
        zone = ZoneInfo(state["settings"]["timezone"])

        def stamped(row):
            # Old turns without a clock make the model treat this morning as "now".
            at = parse(row["created_at"]).astimezone(zone)
            return f"[{at:%H:%M}] {row['text']}"

        messages = [{"role": "system", "content": assistant.SYSTEM_PROMPT + "\n" + assistant.MODES[mode]
                     + f"\n【人设】当前人设：{conf['persona']}。语气按这个人设走，做事规则不变。"},
                    {"role": "system", "content": context},
                    *({"role": row["role"], "content": stamped(row)} for row in reversed(history)),
                    self._turn(text, image)]
        started = time.monotonic()
        calls = 1
        try:
            raw = await assistant.complete(conf, key, messages, transport=self.transport())
        except DomainError as error:
            timings.record(self.store.directory, "assistant.failure", user=(user_id or "")[:8],
                           ms=int((time.monotonic() - started) * 1000), code=error.code,
                           image=bool(image))
            if image:
                return self._exchange(
                    text,
                    f"模型那边没接住这张图（{error.message}）。换个支持看图的模型，或者把图里的内容打字发我。",
                    user_id,
                )
            raise
        try:
            reply = assistant.parse_reply(raw)
        except (ValueError, ValidationError) as error:
            calls += 1
            retry = [*messages, {"role": "assistant", "content": raw[:4000]},
                     {"role": "user", "content": f"上面的输出不符合要求（{str(error)[:200]}）。请只输出符合格式的 JSON 对象。"}]
            raw = await assistant.complete(conf, key, retry, transport=self.transport())
            try:
                reply = assistant.parse_reply(raw)
            except (ValueError, ValidationError):
                reply = assistant.ModelReply(reply="我没能把这些整理成清楚的安排，换个说法再试一次？")
        if not reply.drafts and not reply.reply.strip() and not reply.question:
            # An empty turn means nothing was done; ask once more before telling the user a no-op.
            calls += 1
            retry = [*messages, {"role": "assistant", "content": raw[:4000]},
                     {"role": "user", "content": "你这条回复是空的。他要是让你改日程，就必须给出 drafts；只是闲聊，就用一句话正常回他。"}]
            raw = await assistant.complete(conf, key, retry, transport=self.transport())
            try:
                reply = assistant.parse_reply(raw)
            except (ValueError, ValidationError):
                reply = assistant.ModelReply(reply="刚才没接住，你再说一遍？")
        timings.record(self.store.directory, "assistant.turn", user=(user_id or "")[:8],
                       ms=int((time.monotonic() - started) * 1000), calls=calls,
                       drafts=len(reply.drafts), image=bool(image))
        state = self.store.state(user_id=user_id)
        drafts, notes = assistant.resolve_drafts(reply, state, refs, self.clock(), requested_at=now)
        usable = []
        for draft in drafts:
            trial = deepcopy(state)
            kept = []
            for action in draft['actions']:
                # Validate one action at a time: a stale block must not wipe out the rest of the message.
                try:
                    for kind, payload in assistant.draft_operations(trial, [action], self.clock()):
                        apply(trial, Operation(operation_id=identifier(), kind=kind, payload=payload), 'assistant-preview', self.clock())
                    kept.append(action)
                except (DomainError, ValidationError) as error:
                    notes.append(error.message if isinstance(error, DomainError) else '安排信息不完整，请补充时间或剩余工作量。')
            if kept:
                usable.append({**draft, "actions": kept})
        drafts = usable
        remembered = self._remember(reply.remember, state, request_id, user_id)
        reply_id = identifier()
        draft_ids = [identifier() for _ in drafts]
        quiet, confirm_needed = [], []
        for draft_id, draft in zip(draft_ids, drafts):
            (confirm_needed if needs_confirm(draft, state, zone) else quiet).append(draft_id)
        with self.store.connect() as conn:
            assistant.count_call(conn, now, calls, user_id=user_id)
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?,?)", (identifier(), "user", shown, stamp(now), user_id))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?,?)",
                         (reply_id, "assistant", "", stamp(now + timedelta(microseconds=1)), user_id))
            for draft_id, draft in zip(draft_ids, drafts):
                conn.execute("INSERT INTO assistant_drafts VALUES(?,?,?,?,?,?,?)",
                             (draft_id, reply_id, draft["summary"][:200], encode(draft["actions"]), "pending", stamp(now), user_id))
        applied = 0
        if mode == "auto":
            for draft_id in quiet:
                try:
                    self.apply_draft(draft_id, device_id, user_id)
                    applied += 1
                except DomainError as error:
                    self.dismiss_draft(draft_id, user_id)
                    notes.append(error.message)
        answer_override = None
        if confirm_needed:
            listed = "；".join(draft["summary"] for draft in drafts if needs_confirm(draft, state, zone))
            if applied:
                notes.append(f"另有 {len(confirm_needed)} 处改动偏大，等你确认（回「确认」或「不必」）。")
            else:
                answer_override = (f"这次改动偏大（{len(confirm_needed)} 处），先等你确认：\n{listed}\n"
                                   "要办就回「确认」，不办回「不必」。")
        # Remember what this turn was about, so「它 / 那个」has a referent next turn.
        record = touched_entities(state, drafts)
        before_ids = {item["id"] for item in state.get("tasks", [])} | {item["id"] for item in state.get("blocks", [])}
        after_state = self.store.state(user_id=user_id)
        for item in after_state.get("tasks", []):
            if item["id"] not in before_ids:
                record.append({"kind": "任务", "id": item["id"], "title": item["title"]})
        for item in after_state.get("blocks", []):
            if item["id"] not in before_ids:
                record.append({"kind": "安排", "id": item["id"], "title": item["title"]})
        answer = answer_override or self._answer(reply.reply, mode, len(drafts), applied, notes, remembered)
        if reply.question:
            listed = " ".join(f"{index}. {option}" for index, option in enumerate(reply.question.options, 1))
            answer = reply.question.text + (f"\n{listed}" if listed else "")
            if notes:
                answer += "\n" + "\n".join(notes[:2])
        answer = assistant.visible_text(answer, state, refs)
        with self.store.connect() as conn:
            close_pending_questions(conn, user_id, now)
            remember_entities(conn, user_id, record, now)
            if reply.question:
                ask_question(conn, user_id, now, reply.question)
            conn.execute("UPDATE assistant_messages SET text=? WHERE id=? AND user_id=?", (answer, reply_id, user_id))
            if reply.meme and not notes:
                conn.execute("INSERT OR REPLACE INTO assistant_memes VALUES(?,?,?,?)",
                             (reply_id, reply.meme[:16], stamp(now), user_id))
            elif reply.meme:
                conn.execute("DELETE FROM assistant_memes WHERE message_id=? AND user_id=?", (reply_id, user_id))
            return assistant.message_rows(conn, 2, user_id)

    @staticmethod
    def _turn(text, image):
        """This turn as one OpenAI message: the words, plus the picture when there is one."""
        if not image:
            return {"role": "user", "content": text}
        mime, data = image
        uri = f"data:{mime};base64," + base64.b64encode(data).decode()
        return {"role": "user", "content": [
            {"type": "text", "text": text.strip() or "看看这张图。"},
            {"type": "image_url", "image_url": {"url": uri}}]}

    @staticmethod
    def _answer(said, mode, proposed, applied, notes, remembered):
        """The model's sentence only when it matches what really happened."""
        said = (said or "").strip()
        if proposed:
            # A change has been made or proposed; questions about it ("你定？") only add noise.
            said = "".join(part for part in re.split(r"(?<=[。！？!?\n])", said)
                           if part.strip() and not part.strip().endswith(("？", "?")))
        if mode == "confirm":
            lines = [said or "拟办已整理好，确认后执行。"] if proposed or not notes else ["这次没拟成："]
        elif proposed and applied == proposed:
            lines = [said or "已照办。"]
        elif applied:
            lines = ["只办成了一部分："]
        elif proposed:
            lines = ["这次没能改动日程："]
        elif notes:
            lines = ["这次没动手："]
        else:
            lines = [said or "收到。"]
        lines += notes[:2]
        if remembered:
            lines.append("已记下：" + "；".join(remembered))
        return "\n".join(lines)

    def _remember(self, items, state, request_id, user_id):
        """Durable preferences the user just stated about themselves.

        Same preference said twice (even with punctuation/space differences) keeps
        the first row; a turn may add at most two new ones (plan §9.4)."""
        known = {memory_key(m.get("text", "")) for m in state.get("memories", [])}
        saved = []
        for index, text in enumerate(list(items)[:MAX_REMEMBERED_PER_TURN]):
            text = " ".join(str(text).split())[:1000]
            key = memory_key(text)
            if not text or not key or key in known or len(known) + len(saved) >= MEMORY_LIMIT:
                continue
            known.add(key)
            memory_id = uuid5(NAMESPACE_URL, f"{request_id}:{index}").hex if request_id else identifier()
            try:
                self.apply_operation("memory.save", {"id": memory_id, "text": text, "source": "assistant"},
                                     user_id=user_id)
            except DomainError:
                continue
            saved.append(text)
        return saved

    def apply_draft(self, draft_id, device_id, user_id=None):
        """Run a confirmed draft as ordinary logged operations, all or nothing."""
        user_id = self.user(user_id)
        now = self.clock()
        expire_due(self.store, now, user_id)
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM assistant_drafts WHERE id=? AND user_id=?", (draft_id, user_id)).fetchone()
            if not row:
                raise DomainError("拟办不存在", "NOT_FOUND", 404)
            if row["status"] != "pending":
                raise DomainError("这条拟办已经处理过了")
            if now - parse(row['created_at']) > timedelta(minutes=15):
                raise DomainError('拟办已超过 15 分钟，请按当前状态重新生成', 'STALE_PROPOSAL')
            state = self.store.state(conn, user_id)
            before = deepcopy(state)
            actions = json.loads(row["actions"])
            applied = []
            for kind, payload in assistant.draft_operations(state, actions, now):
                operation = Operation(operation_id=identifier(), kind=kind, payload=payload)
                try:
                    entity = apply(state, operation, device_id, now)
                except ValidationError as error:
                    raise DomainError("拟办内容不完整：" + "; ".join(str(e["msg"]) for e in error.errors()),
                                      "VALIDATION_ERROR", 422) from None
                state["revision"] += 1
                result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
                conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, user_id,
                             digest(encode(operation.model_dump())), encode(result)))
                self.store.record_event(conn, user_id, state["revision"], device_id, kind, payload, now)
                applied.append(kind)
            self.store.save(conn, state, user_id)
            conn.execute("UPDATE assistant_drafts SET status='applied' WHERE id=?", (draft_id,))
            if all(a["type"] in UNDOABLE for a in actions):
                conn.execute("INSERT OR REPLACE INTO assistant_undo VALUES(?,?,?,?)",
                             (draft_id, encode(undo_operations(before, state)), stamp(now), user_id))
        flush_archives(self.store, self.clock())
        return {"revision": state["revision"], "applied": applied}

    def undo_draft(self, draft_id, device_id, user_id=None):
        """Put the schedule back the way it was before an applied draft, all or nothing."""
        user_id = self.user(user_id)
        now = self.clock()
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT d.status, u.operations FROM assistant_drafts d JOIN assistant_undo u "
                               "ON u.draft_id=d.id WHERE d.id=? AND d.user_id=?", (draft_id, user_id)).fetchone()
            if not row or row["status"] != "applied":
                raise DomainError("这条改动不能撤销，或已经撤销过了", "NOT_FOUND", 404)
            state = self.store.state(conn, user_id)
            for kind, payload in json.loads(row["operations"]):
                operation = Operation(operation_id=identifier(), kind=kind, payload=payload)
                try:
                    entity = apply(state, operation, device_id, now)
                except DomainError as error:
                    raise DomainError(f"之后日程又有变化，没法整体撤销：{error.message}", "UNDO_STALE", 409) from None
                state["revision"] += 1
                result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
                conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, user_id,
                             digest(encode(operation.model_dump())), encode(result)))
                self.store.record_event(conn, user_id, state["revision"], device_id, kind, payload, now)
            self.store.save(conn, state, user_id)
            conn.execute("UPDATE assistant_drafts SET status='undone' WHERE id=?", (draft_id,))
            conn.execute("DELETE FROM assistant_undo WHERE draft_id=?", (draft_id,))
        flush_archives(self.store, self.clock())
        return {"revision": state["revision"], "undone": True}

    def dismiss_draft(self, draft_id, user_id=None):
        user_id = self.user(user_id)
        with self.store.connect() as conn:
            result = conn.execute("UPDATE assistant_drafts SET status='dismissed' WHERE id=? AND user_id=? AND status='pending'", (draft_id, user_id))
            if result.rowcount == 0:
                raise DomainError("拟办不存在或已处理", "NOT_FOUND", 404)
        return {"dismissed": True}
