"""Assistant conversation and draft confirmation shared by the app API and WeChat."""
import base64
import json
import re
from copy import deepcopy
from datetime import timedelta
from uuid import uuid5, NAMESPACE_URL
from zoneinfo import ZoneInfo

from pydantic import ValidationError

from . import assistant
from .domain import DomainError, apply, identifier, stamp, parse
from .maintenance import expire_due
from .models import Operation
from .reports import flush_archives
from .store import digest, encode


UNDOABLE = {"schedule_new", "schedule_task", "protect", "move_block", "cancel_block", "cancel_task"}


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


class AssistantService:
    def __init__(self, store, clock, transport=lambda: None):
        self.store, self.clock, self.transport = store, clock, transport
        self.settings = assistant.AssistantSettings(store.directory)
        with store.connect() as conn:
            conn.executescript(assistant.SCHEMA)

    def require(self, conn):
        if not self.settings.configured():
            raise DomainError("助手还没有配置：请在电脑端「设置 · 助手」填写服务地址、模型和 API Key",
                              "ASSISTANT_NOT_CONFIGURED", 409)
        conf = self.settings.load()
        if assistant.usage_today(conn, self.clock()) >= conf["daily_limit"]:
            raise DomainError("今天的助手调用次数已用完，可在电脑端调高上限", "ASSISTANT_LIMIT", 429)
        return conf, self.settings.key()[0]

    def apply_operation(self, kind, payload, device_id="assistant", operation_id=None):
        operation = Operation(operation_id=operation_id or identifier(), kind=kind, payload=payload)
        request_hash = digest(encode(operation.model_dump()))
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            previous = conn.execute("SELECT * FROM operations WHERE id=?", (operation.operation_id,)).fetchone()
            if previous:
                if previous["request_hash"] != request_hash or previous["device_id"] != device_id:
                    raise DomainError("操作标识冲突")
                return json.loads(previous["response"])
            state = self.store.state(conn)
            entity = apply(state, operation, device_id, self.clock())
            state["revision"] += 1
            result = {"revision": state["revision"], "entity": entity, "operation_id": operation.operation_id}
            self.store.save(conn, state)
            conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, self.store.owner_id, request_hash, encode(result)))
            conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device_id, kind, encode(payload), stamp(self.clock())))
        flush_archives(self.store, self.clock())
        return result

    def _exchange(self, text, answer):
        now = self.clock()
        with self.store.connect() as conn:
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (identifier(), "user", text, stamp(now)))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (identifier(), "assistant", answer, stamp(now + timedelta(microseconds=1))))
            return assistant.message_rows(conn, 2)

    async def converse(self, text, request_id=None, device_id="assistant", image=None):
        """One user turn. Returns the stored user + assistant rows (with drafts).

        ``image`` 是 (mime, bytes)：带上它就把图作为这一轮的用户消息一起发给模型看。
        """
        now = self.clock()
        expire_due(self.store, now)
        shown = f"[图片] {text}".strip() if image else text
        memory = re.fullmatch(r"(?:请)?记住[：:]\s*(.{1,1000})", text.strip(), re.S)
        forget = re.fullmatch(r"(?:请)?忘记[：:]\s*(.{1,1000})", text.strip(), re.S)
        if memory:
            memory_id = uuid5(NAMESPACE_URL, request_id).hex if request_id else identifier()
            self.apply_operation("memory.save", {"id": memory_id, "text": memory.group(1).strip()},
                                 operation_id=f'wechat-memory:{request_id}' if request_id else None)
            return self._exchange(text, "已记住。你可以在助手的「记忆」中查看或删除。")
        if forget:
            matches = [m for m in self.store.state().get("memories", []) if m["text"] == forget.group(1).strip()]
            for item in matches:
                self.apply_operation("memory.delete", {"id": item["id"]})
            return self._exchange(text, "已删除这条记忆。" if matches else "没有找到这条记忆，可在助手的「记忆」中查看。")
        with self.store.connect() as conn:
            conf, key = self.require(conn)
            state = self.store.state(conn)
            history = conn.execute("SELECT role,text,created_at FROM assistant_messages WHERE created_at>=? "
                                   "ORDER BY created_at DESC, rowid DESC LIMIT 10",
                                   (stamp(now - timedelta(minutes=45)),)).fetchall()
        # Removing a memory must also keep the original memory command out of model context.
        history = [row for row in history if not (row['role'] == 'user' and re.match(r'^(?:请)?(?:记住|忘记)[：:]', row['text']))]
        context, refs = assistant.build_context(state, now)
        mode = "confirm" if conf.get("confirm_first") else "auto"
        zone = ZoneInfo(state["settings"]["timezone"])

        def stamped(row):
            # Old turns without a clock make the model treat this morning as "now".
            at = parse(row["created_at"]).astimezone(zone)
            return f"[{at:%H:%M}] {row['text']}"

        messages = [{"role": "system", "content": assistant.SYSTEM_PROMPT + "\n" + assistant.MODES[mode]},
                    {"role": "system", "content": context},
                    *({"role": row["role"], "content": stamped(row)} for row in reversed(history)),
                    self._turn(text, image)]
        calls = 1
        raw = await assistant.complete(conf, key, messages, transport=self.transport())
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
        if not reply.drafts and not reply.reply.strip():
            # An empty turn means nothing was done; ask once more before telling the user a no-op.
            calls += 1
            retry = [*messages, {"role": "assistant", "content": raw[:4000]},
                     {"role": "user", "content": "你这条回复是空的。他要是让你改日程，就必须给出 drafts；只是闲聊，就用一句话正常回他。"}]
            raw = await assistant.complete(conf, key, retry, transport=self.transport())
            try:
                reply = assistant.parse_reply(raw)
            except (ValueError, ValidationError):
                reply = assistant.ModelReply(reply="刚才没接住，你再说一遍？")
        state = self.store.state()
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
        remembered = self._remember(reply.remember, state, request_id)
        user_id, reply_id = identifier(), identifier()
        draft_ids = [identifier() for _ in drafts]
        with self.store.connect() as conn:
            assistant.count_call(conn, now, calls)
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (user_id, "user", shown, stamp(now)))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)",
                         (reply_id, "assistant", "", stamp(now + timedelta(microseconds=1))))
            for draft_id, draft in zip(draft_ids, drafts):
                conn.execute("INSERT INTO assistant_drafts VALUES(?,?,?,?,?,?)",
                             (draft_id, reply_id, draft["summary"][:200], encode(draft["actions"]), "pending", stamp(now)))
        applied = 0
        if mode == "auto":
            for draft_id in draft_ids:
                try:
                    self.apply_draft(draft_id, device_id)
                    applied += 1
                except DomainError as error:
                    self.dismiss_draft(draft_id)
                    notes.append(error.message)
        answer = self._answer(reply.reply, mode, len(drafts), applied, notes, remembered)
        answer = assistant.visible_text(answer, state, refs)
        with self.store.connect() as conn:
            conn.execute("UPDATE assistant_messages SET text=? WHERE id=?", (answer, reply_id))
            if reply.meme and not notes:
                conn.execute("INSERT OR REPLACE INTO assistant_memes VALUES(?,?,?)",
                             (reply_id, reply.meme[:16], stamp(now)))
            elif reply.meme:
                conn.execute("DELETE FROM assistant_memes WHERE message_id=?", (reply_id,))
            return assistant.message_rows(conn, 2)

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

    def _remember(self, items, state, request_id):
        """Durable preferences the user just stated about themselves."""
        known = {m["text"] for m in state.get("memories", [])}
        saved = []
        for index, text in enumerate(items):
            text = text.strip()[:1000]
            if not text or text in known or len(known) + len(saved) >= 50:
                continue
            memory_id = uuid5(NAMESPACE_URL, f"{request_id}:{index}").hex if request_id else identifier()
            try:
                self.apply_operation("memory.save", {"id": memory_id, "text": text, "source": "assistant"})
            except DomainError:
                continue
            saved.append(text)
        return saved

    def apply_draft(self, draft_id, device_id):
        """Run a confirmed draft as ordinary logged operations, all or nothing."""
        now = self.clock()
        expire_due(self.store, now)
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM assistant_drafts WHERE id=?", (draft_id,)).fetchone()
            if not row:
                raise DomainError("拟办不存在", "NOT_FOUND", 404)
            if row["status"] != "pending":
                raise DomainError("这条拟办已经处理过了")
            if now - parse(row['created_at']) > timedelta(minutes=15):
                raise DomainError('拟办已超过 15 分钟，请按当前状态重新生成', 'STALE_PROPOSAL')
            state = self.store.state(conn)
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
                conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, self.store.owner_id,
                             digest(encode(operation.model_dump())), encode(result)))
                conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device_id, kind,
                             encode(payload), stamp(now)))
                applied.append(kind)
            self.store.save(conn, state)
            conn.execute("UPDATE assistant_drafts SET status='applied' WHERE id=?", (draft_id,))
            if all(a["type"] in UNDOABLE for a in actions):
                conn.execute("INSERT OR REPLACE INTO assistant_undo VALUES(?,?,?)",
                             (draft_id, encode(undo_operations(before, state)), stamp(now)))
        flush_archives(self.store, self.clock())
        return {"revision": state["revision"], "applied": applied}

    def undo_draft(self, draft_id, device_id):
        """Put the schedule back the way it was before an applied draft, all or nothing."""
        now = self.clock()
        with self.store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT d.status, u.operations FROM assistant_drafts d JOIN assistant_undo u "
                               "ON u.draft_id=d.id WHERE d.id=?", (draft_id,)).fetchone()
            if not row or row["status"] != "applied":
                raise DomainError("这条改动不能撤销，或已经撤销过了", "NOT_FOUND", 404)
            state = self.store.state(conn)
            for kind, payload in json.loads(row["operations"]):
                operation = Operation(operation_id=identifier(), kind=kind, payload=payload)
                try:
                    entity = apply(state, operation, device_id, now)
                except DomainError as error:
                    raise DomainError(f"之后日程又有变化，没法整体撤销：{error.message}", "UNDO_STALE", 409) from None
                state["revision"] += 1
                result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
                conn.execute("INSERT INTO operations(id, device_id, user_id, request_hash, response) VALUES(?,?,?,?,?)", (operation.operation_id, device_id, self.store.owner_id,
                             digest(encode(operation.model_dump())), encode(result)))
                conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device_id, kind,
                             encode(payload), stamp(now)))
            self.store.save(conn, state)
            conn.execute("UPDATE assistant_drafts SET status='undone' WHERE id=?", (draft_id,))
            conn.execute("DELETE FROM assistant_undo WHERE draft_id=?", (draft_id,))
        flush_archives(self.store, self.clock())
        return {"revision": state["revision"], "undone": True}

    def dismiss_draft(self, draft_id):
        with self.store.connect() as conn:
            result = conn.execute("UPDATE assistant_drafts SET status='dismissed' WHERE id=? AND status='pending'", (draft_id,))
            if result.rowcount == 0:
                raise DomainError("拟办不存在或已处理", "NOT_FOUND", 404)
        return {"dismissed": True}
