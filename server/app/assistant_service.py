"""Assistant conversation and draft confirmation shared by the app API and WeChat."""
import json
from datetime import timedelta

from pydantic import ValidationError

from . import assistant
from .domain import DomainError, apply, identifier, stamp
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

    async def converse(self, text):
        """One user turn. Returns the stored user + assistant rows (with drafts)."""
        now = self.clock()
        expire_due(self.store, now)
        with self.store.connect() as conn:
            conf, key = self.require(conn)
            state = self.store.state(conn)
            history = conn.execute("SELECT role,text FROM assistant_messages ORDER BY created_at DESC, rowid DESC LIMIT 10").fetchall()
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
        drafts, notes = assistant.resolve_drafts(reply, state, refs, now)
        answer = "\n".join(filter(None, [reply.reply or ("拟办如下，确认后生效。" if drafts else "收到。"), *notes]))
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
        flush_archives(self.store)
        return {"revision": state["revision"], "applied": applied}

    def dismiss_draft(self, draft_id):
        with self.store.connect() as conn:
            result = conn.execute("UPDATE assistant_drafts SET status='dismissed' WHERE id=? AND status='pending'", (draft_id,))
            if result.rowcount == 0:
                raise DomainError("拟办不存在或已处理", "NOT_FOUND", 404)
        return {"dismissed": True}
