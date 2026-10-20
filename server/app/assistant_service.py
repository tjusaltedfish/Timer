"""Assistant conversation and draft confirmation shared by the app API and WeChat."""
import json
import re
from copy import deepcopy
from datetime import timedelta
from uuid import uuid5, NAMESPACE_URL

from pydantic import ValidationError

from . import assistant
from .domain import DomainError, apply, identifier, stamp, parse
from .maintenance import expire_due
from .models import Operation
from .reports import flush_archives
from .store import digest, encode


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
            conn.execute("INSERT INTO operations VALUES(?,?,?,?)", (operation.operation_id, device_id, request_hash, encode(result)))
            conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device_id, kind, encode(payload), stamp(self.clock())))
        flush_archives(self.store, self.clock())
        return result

    def _exchange(self, text, answer):
        now = self.clock()
        with self.store.connect() as conn:
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (identifier(), "user", text, stamp(now)))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (identifier(), "assistant", answer, stamp(now + timedelta(microseconds=1))))
            return assistant.message_rows(conn, 2)

    async def converse(self, text, request_id=None):
        """One user turn. Returns the stored user + assistant rows (with drafts)."""
        now = self.clock()
        expire_due(self.store, now)
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
            history = conn.execute("SELECT role,text FROM assistant_messages ORDER BY created_at DESC, rowid DESC LIMIT 10").fetchall()
        # Removing a memory must also keep the original memory command out of model context.
        history = [row for row in history if not (row['role'] == 'user' and re.match(r'^(?:请)?(?:记住|忘记)[：:]', row['text']))]
        context, refs = assistant.build_context(state, now)
        messages = [{"role": "system", "content": assistant.SYSTEM_PROMPT},
                    {"role": "system", "content": context},
                    *({"role": row["role"], "content": row["text"]} for row in reversed(history)),
                    {"role": "user", "content": text}]
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
        state = self.store.state()
        drafts, notes = assistant.resolve_drafts(reply, state, refs, self.clock(), requested_at=now)
        usable = []
        for draft in drafts:
            trial = deepcopy(state)
            try:
                for kind, payload in assistant.draft_operations(trial, draft['actions'], self.clock()):
                    apply(trial, Operation(operation_id=identifier(), kind=kind, payload=payload), 'assistant-preview', self.clock())
                usable.append(draft)
            except (DomainError, ValidationError) as error:
                notes.append(error.message if isinstance(error, DomainError) else '安排信息不完整，请补充时间或剩余工作量。')
        drafts = usable
        answer = "拟办已整理好，确认后执行。" if drafts else reply.reply or "收到。"
        answer = "\n".join([answer, *notes])
        for short, real_id in refs.items():
            title = next((v["title"] for group in (state["tasks"], state["blocks"]) for v in group if v["id"] == real_id), None)
            if title:
                answer = re.sub(r"\b" + re.escape(short) + r"\b", title, answer)
        user_id, reply_id = identifier(), identifier()
        with self.store.connect() as conn:
            assistant.count_call(conn, now, calls)
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (user_id, "user", text, stamp(now)))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)",
                         (reply_id, "assistant", answer, stamp(now + timedelta(microseconds=1))))
            for draft in drafts:
                conn.execute("INSERT INTO assistant_drafts VALUES(?,?,?,?,?,?)",
                             (identifier(), reply_id, draft["summary"][:200], encode(draft["actions"]), "pending", stamp(now)))
            return assistant.message_rows(conn, 2)

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
            applied = []
            for kind, payload in assistant.draft_operations(state, json.loads(row["actions"]), now):
                operation = Operation(operation_id=identifier(), kind=kind, payload=payload)
                try:
                    entity = apply(state, operation, device_id, now)
                except ValidationError as error:
                    raise DomainError("拟办内容不完整：" + "; ".join(str(e["msg"]) for e in error.errors()),
                                      "VALIDATION_ERROR", 422) from None
                state["revision"] += 1
                result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
                conn.execute("INSERT INTO operations VALUES(?,?,?,?)", (operation.operation_id, device_id,
                             digest(encode(operation.model_dump())), encode(result)))
                conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device_id, kind,
                             encode(payload), stamp(now)))
                applied.append(kind)
            self.store.save(conn, state)
            conn.execute("UPDATE assistant_drafts SET status='applied' WHERE id=?", (draft_id,))
        flush_archives(self.store, self.clock())
        return {"revision": state["revision"], "applied": applied}

    def dismiss_draft(self, draft_id):
        with self.store.connect() as conn:
            result = conn.execute("UPDATE assistant_drafts SET status='dismissed' WHERE id=? AND status='pending'", (draft_id,))
            if result.rowcount == 0:
                raise DomainError("拟办不存在或已处理", "NOT_FOUND", 404)
        return {"dismissed": True}
