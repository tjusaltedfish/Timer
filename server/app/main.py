import json
import os
import secrets
from datetime import timedelta
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from .domain import DomainError, apply, stamp, identifier, parse
from .models import Operation, PairConfirm, PlanRequest
from .planning import propose
from .reports import flush_archives, report_for
from .store import Store, digest, encode, utcnow


def create_app(directory=None, clock=utcnow):
    directory = Path(directory or os.environ.get("PLANNER_DATA_DIR", Path(__file__).resolve().parents[2] / "data"))
    store = Store(directory)

    @asynccontextmanager
    async def lifespan(app):
        flush_archives(store)
        yield

    app = FastAPI(title="个人弹性日程助手", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.desktop_token = store.desktop_token
    pairing_attempts = {}

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

    return app


app = create_app()
