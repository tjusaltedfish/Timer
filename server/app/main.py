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
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from pydantic import ValidationError

from . import assistant, releases
from .assistant_service import AssistantService
from .proactive import Proactive
from .weekly import WeeklyBrief
from .materials import MaterialService, GenerateReview, MAX_FILE
from .wechat import WeChatChannel, WeChatConfigIn, parse_message, signature_ok
from .domain import DomainError, apply, stamp, identifier, parse
from .models import Operation, PairConfirm, PlanRequest
from .planning import propose
from .maintenance import expire_due
from .reports import flush_archives, report_for
from .store import Store, digest, encode, utcnow


def create_app(directory=None, clock=utcnow, llm_transport=None, wechat_transport=None, background=True):
    directory = Path(directory or releases.default_data_dir())
    store = Store(directory)

    @asynccontextmanager
    async def lifespan(app):
        expire_due(store, clock())
        flush_archives(store, clock())
        async def maintain():
            while True:
                await asyncio.sleep(5)
                try:
                    expire_due(store, clock())
                    flush_archives(store, clock())
                except (OSError, RuntimeError):
                    logging.getLogger(__name__).exception("Background maintenance will retry")
        async def wechat_worker():
            while True:
                try:
                    app.state.proactive.tick()
                    await app.state.wechat.run_once()
                except Exception:  # noqa: BLE001 - the queue keeps its evidence; retry next round
                    logging.getLogger(__name__).exception("WeChat worker will retry")
                await asyncio.sleep(3)
        workers = [asyncio.create_task(maintain())]
        if background:
            workers.append(asyncio.create_task(wechat_worker()))
            async def review_worker():
                while True:
                    try:
                        await app.state.materials.generate_due()
                    except Exception:
                        logging.getLogger(__name__).exception('Daily review worker will retry')
                    try:
                        await app.state.weekly.run_due()
                    except Exception:
                        logging.getLogger(__name__).exception('Weekly brief will retry')
                    await asyncio.sleep(60)
            workers.append(asyncio.create_task(review_worker()))
        try:
            yield
        finally:
            for worker in workers:
                worker.cancel()
            for worker in workers:
                with suppress(asyncio.CancelledError):
                    await worker

    version = releases.source_version()
    app = FastAPI(title="个人弹性日程助手", version=version, lifespan=lifespan)
    app.state.store = store
    app.state.desktop_token = store.desktop_token
    pairing_attempts = {}
    app.state.llm_transport = llm_transport
    app.state.wechat_transport = wechat_transport

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
        latest = releases.read_latest(store.directory)
        return {"status": "ok", "version": version, "app_latest": latest["version"] if latest else None}

    @app.get("/api/v1/snapshot")
    def snapshot(device=Depends(authenticated)):
        expire_due(store, clock())
        state = store.state()
        state["server_time"] = stamp(clock())
        state["device"] = device
        latest = releases.read_latest(store.directory)
        state["server_version"] = version
        state["app_latest"] = releases.public(latest)
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
        if address in ("127.0.0.1", "::1") and request.headers.get("cf-connecting-ip"):
            # Through the local Cloudflare tunnel every caller looks like localhost.
            address = request.headers["cf-connecting-ip"]
        attempts =[at for at in pairing_attempts.get(address, []) if clock() - at < timedelta(minutes=1)]
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
        flush_archives(store, clock())
        return result

    @app.get("/api/v1/reports/{day}")
    def report(day: str, device=Depends(authenticated)):
        from datetime import date
        try:
            date.fromisoformat(day)
        except ValueError:
            raise DomainError("日期格式无效", status=422) from None
        return report_for(store.state(), day, clock())

    # ---- Assistant ------------------------------------------------------
    service = AssistantService(store, clock, lambda: app.state.llm_transport)
    app.state.assistant = service
    materials = MaterialService(service)
    app.state.materials = materials
    assistant_settings = service.settings

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
            conf, key = service.require(conn)
            assistant.count_call(conn, clock())
        started, fixed = time.monotonic(), None
        ping = [{"role": "user", "content": "只回复两个字：在的"}]
        try:
            reply = await assistant.complete(conf, key, ping, json_mode=False, transport=app.state.llm_transport)
        except DomainError as error:
            base = conf["base_url"].rstrip("/")
            if error.code in ("LLM_PAGE", "LLM_NOT_FOUND") and not base.endswith("/v1"):
                # Relays usually serve their website at the bare host; try the API path once.
                candidate = {**conf, "base_url": base + "/v1"}
                try:
                    reply = await assistant.complete(candidate, key, ping, json_mode=False,
                                                     transport=app.state.llm_transport)
                except DomainError:
                    raise error from None
                assistant_settings.update(assistant.AssistantConfigIn(base_url=candidate["base_url"]))
                fixed = candidate["base_url"]
            elif error.code == "LLM_MODEL":
                models = await assistant.list_models(conf, key, app.state.llm_transport)
                if models:
                    raise DomainError(f"{error.message}。这个服务可用的模型：{'、'.join(models[:20])}",
                                      error.code, error.status) from None
                raise
            else:
                raise
        return {"ok": True, "reply": reply.strip()[:80], "latency_ms": int((time.monotonic() - started) * 1000),
                "model": conf["model"], "fixed_base_url": fixed}

    @app.get("/api/v1/assistant/models")
    async def assistant_models(device=Depends(desktop)):
        conf, key = assistant_settings.load(), assistant_settings.key()[0]
        if not (conf["base_url"] and key):
            raise DomainError("先填写服务地址和 API Key", "ASSISTANT_NOT_CONFIGURED", 409)
        return {"models": await assistant.list_models(conf, key, app.state.llm_transport)}

    @app.get("/api/v1/assistant/messages")
    def assistant_history(device=Depends(authenticated)):
        with store.connect() as conn:
            return {"messages": assistant.message_rows(conn)}

    @app.post("/api/v1/assistant/messages")
    async def assistant_message(data: assistant.AssistantMessageIn, device=Depends(authenticated)):
        return {"messages": await service.converse(data.text)}

    @app.post("/api/v1/assistant/drafts/{draft_id}/apply")
    def assistant_apply(draft_id: str, device=Depends(authenticated)):
        return service.apply_draft(draft_id, device["id"])

    @app.post("/api/v1/assistant/drafts/{draft_id}/dismiss")
    def assistant_dismiss(draft_id: str, device=Depends(authenticated)):
        return service.dismiss_draft(draft_id)

    @app.post("/api/v1/assistant/drafts/{draft_id}/undo")
    def assistant_undo(draft_id: str, device=Depends(authenticated)):
        return service.undo_draft(draft_id, device["id"])

    # ---- WeChat official-account channel --------------------------------
    channel = WeChatChannel(store, clock, service, lambda: app.state.wechat_transport)
    app.state.wechat = channel
    app.state.proactive = Proactive(store, channel, clock)
    app.state.weekly = WeeklyBrief(store, channel, service, clock)
    channel.notification_valid = app.state.proactive.valid

    @app.get("/wechat/callback")
    def wechat_verify(signature: str = "", timestamp: str = "", nonce: str = "", echostr: str = ""):
        # WeChat's URL check: echo back only when the Token signature matches.
        if not signature_ok(channel.settings.token(), signature, timestamp, nonce, clock()):
            return PlainTextResponse("forbidden", status_code=403)
        return PlainTextResponse(echostr)

    @app.post("/wechat/callback")
    async def wechat_push(request: Request, signature: str = "", timestamp: str = "", nonce: str = ""):
        if not signature_ok(channel.settings.token(), signature, timestamp, nonce, clock()):
            return PlainTextResponse("forbidden", status_code=403)
        body = await request.body()
        try:
            message = parse_message(body)
        except DomainError:
            return PlainTextResponse("success")  # Malformed pushes are dropped, never retried.
        if channel.receive(message) and background:
            asyncio.create_task(channel.run_once())
        return PlainTextResponse("success")

    @app.get("/api/v1/wechat/config")
    def wechat_config(device=Depends(authenticated)):
        return channel.settings.public(device["role"] == "desktop")

    @app.post("/api/v1/wechat/config")
    def wechat_configure(data: WeChatConfigIn, device=Depends(desktop)):
        channel.settings.update(data)
        return channel.settings.public(True)

    @app.post("/api/v1/wechat/bind-code")
    def wechat_bind_code(device=Depends(desktop)):
        return channel.new_bind_code()

    @app.post("/api/v1/wechat/unbind")
    def wechat_unbind(device=Depends(desktop)):
        return channel.unbind()

    @app.post("/api/v1/wechat/test")
    async def wechat_test(device=Depends(desktop)):
        channel.enqueue("这是一条来自瞬时的测试消息。收到就说明电脑后台能给你发微信了。")
        if background:
            asyncio.create_task(channel.run_once())
        return {"queued": True}

    @app.get("/api/v1/wechat/outbox")
    def wechat_outbox(device=Depends(desktop)):
        return {"messages": channel.outbox()}

    @app.post('/api/v1/materials/upload')
    async def upload_material(request: Request, name: str, day: str, description: str = '', external_allowed: bool = True, device=Depends(authenticated)):
        content = bytearray()
        async for chunk in request.stream():
            content.extend(chunk)
            if len(content) > MAX_FILE:
                raise DomainError('文件超过 8 MB', status=413)
        if len(description) > 2000:
            raise DomainError('说明过长', status=422)
        try:
            return await asyncio.to_thread(materials.upload, name, day, description, external_allowed, bytes(content))
        except ValueError:
            raise DomainError('日期格式无效', status=422) from None

    @app.post('/api/v1/reviews/generate')
    async def generate_review(data: GenerateReview, device=Depends(authenticated)):
        try:
            return await materials.generate(data)
        except ValueError:
            raise DomainError('日期或材料格式无效', status=422) from None

    # ---- Phone app releases (published by tools/release.ps1) -------------
    @app.get("/api/v1/app/latest")
    def app_latest(device=Depends(authenticated)):
        latest = releases.read_latest(store.directory)
        if not latest:
            raise DomainError("电脑上还没有发布手机版安装包", "NO_RELEASE", 404)
        return releases.public(latest)

    @app.get("/api/v1/app/download")
    def app_download(device=Depends(authenticated)):
        latest = releases.read_latest(store.directory)
        if not latest:
            raise DomainError("电脑上还没有发布手机版安装包", "NO_RELEASE", 404)
        return FileResponse(releases.apk_path(store.directory, latest),
                            media_type="application/vnd.android.package-archive",
                            filename=latest["file"],
                            headers={"X-Timer-Sha256": latest["sha256"], "X-Timer-Version": latest["version"]})

    return app


app = create_app()
