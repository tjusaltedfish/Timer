import json
import time
import os
import secrets
import asyncio
import logging
from datetime import timedelta
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from . import assistant
from .domain import DomainError, apply, stamp, identifier, parse
from .models import Operation, PairConfirm, PlanRequest
from .planning import propose
from .maintenance import expire_due
from .reports import flush_archives, report_for
from .store import Store, digest, encode, utcnow


def create_app(directory=None, clock=utcnow, llm_transport=None):
    default_data = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".local" / "share")) / "TimePlanner" / "data"
    directory = Path(directory or os.environ.get("PLANNER_DATA_DIR", default_data))
    store = Store(directory)

    @asynccontextmanager
    async def lifespan(app):
        expire_due(store, clock())
        flush_archives(store)
        async def maintain():
            while True:
                await asyncio.sleep(5)
                try:
                    expire_due(store, clock())
                    flush_archives(store)
                except (OSError, RuntimeError):
                    logging.getLogger(__name__).exception("Background maintenance will retry")
        worker = asyncio.create_task(maintain())
        try:
            yield
        finally:
            worker.cancel()
            with suppress(asyncio.CancelledError):
                await worker

    app = FastAPI(title="个人弹性日程助手", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.desktop_token = store.desktop_token
    pairing_attempts = {}
    app.state.llm_transport = llm_transport

    @app.exception_handler(DomainError)
    async def domain_error(request, error):
        return JSONResponse({"code": error.code, "message": error.message}, status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def request_error(request, error):
        return JSONResponse({"code": "VALIDATION_ERROR", "message": "输入格式不正确，请检查必填项和时间", "field_errors": [str(e["loc"]) for e in error.errors()]}, status_code=422)

    @app.middleware("http")
    async def headers(request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        return response

    def authenticated(authorization: str = Header(default="")):
        token = authorization.removeprefix("Bearer ") if authorization.startswith("Bearer ") else ""
        device = store.authenticate(token)
        if device is None:
            raise DomainError("设备尚未配对，或授权已失效", "UNAUTHORIZED", 401)
        return device

    def desktop(device=Depends(authenticated)):
        if device["role"] != "desktop":
            raise DomainError("这项设置需要在电脑端操作", "DESKTOP_REQUIRED", 403)
        return device

    @app.get("/health")
    def health():
        return {"status": "ok", "version": "0.1.0"}

    @app.get("/api/v1/snapshot")
    def snapshot(device=Depends(authenticated)):
        expire_due(store, clock())
        state = store.state()
        state["server_time"] = stamp(clock())
        state["device"] = device
        return state

    @app.post("/api/v1/pairing/code")
    def pairing_code(device=Depends(desktop)):
        code = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
        expiry = stamp(clock() + timedelta(minutes=5))
        with store.connect() as conn:
            conn.execute("DELETE FROM pairing")
            conn.execute("INSERT INTO pairing VALUES(?,?)", (digest(code), expiry))
        return {"code": code, "expires_at": expiry}

    @app.post("/api/v1/pairing/confirm")
    def pairing_confirm(data: PairConfirm, request: Request):
        address = request.client.host if request.client else "unknown"
        attempts = [at for at in pairing_attempts.get(address, []) if clock() - at < timedelta(minutes=1)]
        if len(attempts) >= 10:
            raise DomainError("尝试过多，请一分钟后重试", "RATE_LIMITED", 429)
        pairing_attempts[address] = [*attempts, clock()]
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            entry = conn.execute("SELECT * FROM pairing WHERE code_hash=?", (digest(data.code),)).fetchone()
            if not entry or parse(entry["expires_at"]) <= clock():
                raise DomainError("配对码无效或已过期", "INVALID_PAIRING_CODE", 401)
            conn.execute("DELETE FROM pairing WHERE code_hash=?", (digest(data.code),))
            token, device_id = secrets.token_urlsafe(32), identifier()
            conn.execute("INSERT INTO devices(id,name,role,token_hash) VALUES(?,?,?,?)", (device_id, data.name, "phone", digest(token)))
        return {"device_id": device_id, "token": token}

    @app.get("/api/v1/devices")
    def devices(device=Depends(desktop)):
        with store.connect() as conn:
            return [dict(row) for row in conn.execute("SELECT id,name,role,revoked,ack_revision FROM devices")]

    @app.post("/api/v1/devices/{device_id}/revoke")
    def revoke(device_id: str, device=Depends(desktop)):
        if device_id == "desktop":
            raise DomainError("不能撤销当前电脑的启动凭证")
        with store.connect() as conn:
            result = conn.execute("UPDATE devices SET revoked=1 WHERE id=?", (device_id,))
            if result.rowcount == 0:
                raise DomainError("设备不存在", status=404)
        return {"revoked": True}

    @app.post("/api/v1/plan/proposals")
    def plan_preview(data: PlanRequest, device=Depends(authenticated)):
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            state = store.state(conn)
            proposal = propose(state, data, clock())
            state["proposals"].append(proposal)
            store.save(conn, state)
        return proposal

    @app.post("/api/v1/operations")
    def mutate(operation: Operation, device=Depends(authenticated)):
        expire_due(store, clock())
        request_hash = digest(encode(operation.model_dump()))
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            prior = conn.execute("SELECT * FROM operations WHERE id=?", (operation.operation_id,)).fetchone()
            if prior:
                if prior["device_id"] != device["id"] or prior["request_hash"] != request_hash:
                    raise DomainError("操作编号已被其他内容使用", "OPERATION_ID_REUSED")
                return json.loads(prior["response"])
            state = store.state(conn)
            try:
                entity = apply(state, operation, device["id"], clock())
            except ValidationError as error:
                raise DomainError("输入不符合要求：" + "; ".join(str(e["msg"]) for e in error.errors()), "VALIDATION_ERROR", 422) from None
            state["revision"] += 1
            result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
            serialized = encode(result)
            store.save(conn, state)
            conn.execute("INSERT INTO operations VALUES(?,?,?,?)", (operation.operation_id, device["id"], request_hash, serialized))
            conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device["id"], operation.kind, encode(operation.payload), stamp(clock())))
        flush_archives(store)
        return result

    @app.get("/api/v1/reports/{day}")
    def report(day: str, device=Depends(authenticated)):
        from datetime import date
        try:
            date.fromisoformat(day)
        except ValueError:
            raise DomainError("日期格式无效", status=422) from None
        return report_for(store.state(), day)

    # ---- Assistant ------------------------------------------------------
    with store.connect() as conn:
        conn.executescript(assistant.SCHEMA)
    assistant_settings = assistant.AssistantSettings(store.directory)

    def require_assistant(conn):
        if not assistant_settings.configured():
            raise DomainError("助手还没有配置：请在电脑端「设置 · 助手」填写服务地址、模型和 API Key",
                              "ASSISTANT_NOT_CONFIGURED", 409)
        conf = assistant_settings.load()
        if assistant.usage_today(conn, clock()) >= conf["daily_limit"]:
            raise DomainError("今天的助手调用次数已用完，可在电脑端调高上限", "ASSISTANT_LIMIT", 429)
        return conf, assistant_settings.key()[0]

    @app.get("/api/v1/assistant/config")
    def assistant_config(device=Depends(authenticated)):
        with store.connect() as conn:
            return assistant_settings.public(assistant.usage_today(conn, clock()))

    @app.post("/api/v1/assistant/config")
    def assistant_configure(data: assistant.AssistantConfigIn, device=Depends(desktop)):
        assistant_settings.update(data)
        with store.connect() as conn:
            return assistant_settings.public(assistant.usage_today(conn, clock()))

    @app.post("/api/v1/assistant/test")
    async def assistant_test(device=Depends(desktop)):
        with store.connect() as conn:
            conf, key = require_assistant(conn)
            assistant.count_call(conn, clock())
        started = time.monotonic()
        reply = await assistant.complete(conf, key, [{"role": "user", "content": "只回复两个字：在的"}],
                                         json_mode=False, transport=app.state.llm_transport)
        return {"ok": True, "reply": reply.strip()[:80], "latency_ms": int((time.monotonic() - started) * 1000),
                "model": conf["model"]}

    @app.get("/api/v1/assistant/messages")
    def assistant_history(device=Depends(authenticated)):
        with store.connect() as conn:
            return {"messages": assistant.message_rows(conn)}

    @app.post("/api/v1/assistant/messages")
    async def assistant_message(data: assistant.AssistantMessageIn, device=Depends(authenticated)):
        now = clock()
        expire_due(store, now)
        with store.connect() as conn:
            conf, key = require_assistant(conn)
            state = store.state(conn)
            history = conn.execute("SELECT role,text FROM assistant_messages ORDER BY created_at DESC, rowid DESC LIMIT 10").fetchall()
        context, refs = assistant.build_context(state, now)
        messages = [{"role": "system", "content": assistant.SYSTEM_PROMPT},
                    {"role": "system", "content": context},
                    *({"role": row["role"], "content": row["text"]} for row in reversed(history)),
                    {"role": "user", "content": data.text}]
        calls = 1
        raw = await assistant.complete(conf, key, messages, transport=app.state.llm_transport)
        try:
            reply = assistant.parse_reply(raw)
        except (ValueError, ValidationError) as error:
            calls += 1
            retry = [*messages, {"role": "assistant", "content": raw[:4000]},
                     {"role": "user", "content": f"上面的输出不符合要求（{str(error)[:200]}）。请只输出符合格式的 JSON 对象。"}]
            raw = await assistant.complete(conf, key, retry, transport=app.state.llm_transport)
            try:
                reply = assistant.parse_reply(raw)
            except (ValueError, ValidationError):
                reply = assistant.ModelReply(reply="我没能把这些整理成清楚的安排，换个说法再试一次？")
        drafts, notes = assistant.resolve_drafts(reply, state, refs, now)
        text = "\n".join(filter(None, [reply.reply or ("拟办如下，确认后生效。" if drafts else "收到。"), *notes]))
        user_id, reply_id = identifier(), identifier()
        with store.connect() as conn:
            assistant.count_call(conn, now, calls)
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)", (user_id, "user", data.text, stamp(now)))
            conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?)",
                         (reply_id, "assistant", text, stamp(now + timedelta(microseconds=1))))
            for draft in drafts:
                conn.execute("INSERT INTO assistant_drafts VALUES(?,?,?,?,?,?)",
                             (identifier(), reply_id, draft["summary"][:200], encode(draft["actions"]), "pending", stamp(now)))
            return {"messages": [m for m in assistant.message_rows(conn, 2)]}

    @app.post("/api/v1/assistant/drafts/{draft_id}/apply")
    def assistant_apply(draft_id: str, device=Depends(authenticated)):
        now = clock()
        expire_due(store, now)
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM assistant_drafts WHERE id=?", (draft_id,)).fetchone()
            if not row:
                raise DomainError("拟办不存在", "NOT_FOUND", 404)
            if row["status"] != "pending":
                raise DomainError("这条拟办已经处理过了")
            state = store.state(conn)
            applied = []
            # Every confirmed action is an ordinary logged operation; any failure rolls all back.
            for kind, payload in assistant.draft_operations(state, json.loads(row["actions"]), now):
                operation = Operation(operation_id=identifier(), kind=kind, payload=payload)
                try:
                    entity = apply(state, operation, device["id"], now)
                except ValidationError as error:
                    raise DomainError("拟办内容不完整：" + "; ".join(str(e["msg"]) for e in error.errors()),
                                      "VALIDATION_ERROR", 422) from None
                state["revision"] += 1
                result = {"revision": state["revision"], "operation_id": operation.operation_id, "entity": entity}
                conn.execute("INSERT INTO operations VALUES(?,?,?,?)", (operation.operation_id, device["id"],
                             digest(encode(operation.model_dump())), encode(result)))
                conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], device["id"], kind,
                             encode(payload), stamp(now)))
                applied.append(kind)
            store.save(conn, state)
            conn.execute("UPDATE assistant_drafts SET status='applied' WHERE id=?", (draft_id,))
        flush_archives(store)
        return {"revision": state["revision"], "applied": applied}

    @app.post("/api/v1/assistant/drafts/{draft_id}/dismiss")
    def assistant_dismiss(draft_id: str, device=Depends(authenticated)):
        with store.connect() as conn:
            result = conn.execute("UPDATE assistant_drafts SET status='dismissed' WHERE id=? AND status='pending'", (draft_id,))
            if result.rowcount == 0:
                raise DomainError("拟办不存在或已处理", "NOT_FOUND", 404)
        return {"dismissed": True}

    return app


app = create_app()
