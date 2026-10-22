import json
import re
import time
import os
import secrets
import asyncio
import logging
from datetime import timedelta
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import Depends, FastAPI, Header, Request
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response, StreamingResponse
from pydantic import ValidationError

from . import assistant, auth, releases, tenancy
from .assistant_service import AssistantService
from .channel_identity import CHANNELS, IdentityStore
from .proactive import Proactive
from .weekly import WeeklyBrief
from .materials import MaterialService, GenerateReview, MAX_FILE
from .wechat import WeChatChannel, WeChatConfigIn, parse_message, signature_ok
from .qq import QQChannel, QQConfigIn
from .channels import RoutedChannel
from .domain import DomainError, stamp, identifier, parse
from .models import Operation, PairConfirm, PlanRequest
from .planning import propose
from .maintenance import compact_all, expire_due
from .repo import Repository
from .reports import flush_archives, report_for
from .store import Store, digest, encode, utcnow


def create_app(directory=None, clock=utcnow, llm_transport=None, wechat_transport=None, qq_transport=None, qq_connect=None, background=True):
    directory = Path(directory or releases.default_data_dir())
    store = Store(directory)
    repo = Repository(store)

    @asynccontextmanager
    async def lifespan(app):
        expire_due(store, clock())
        flush_archives(store, clock())
        async def maintain():
            ticks = 0
            while True:
                await asyncio.sleep(5)
                ticks += 1
                try:
                    expire_due(store, clock())
                    flush_archives(store, clock())
                    if ticks % 720 == 0:  # roughly hourly: trim history nobody rereads
                        compact_all(store, clock())
                except (OSError, RuntimeError):
                    logging.getLogger(__name__).exception("Background maintenance will retry")
        async def channel_worker():
            while True:
                try:
                    app.state.proactive.tick()
                    await asyncio.gather(app.state.wechat.run_once(), app.state.qq.run_once())
                except Exception:  # noqa: BLE001 - the queue keeps its evidence; retry next round
                    logging.getLogger(__name__).exception("Chat worker will retry")
                await asyncio.sleep(3)
        workers = [asyncio.create_task(maintain())]
        if background:
            workers.append(asyncio.create_task(channel_worker()))
            workers.append(asyncio.create_task(app.state.qq.serve()))
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
    app.state.repo = repo
    app.state.desktop_token = store.desktop_token
    pairing_attempts = {}
    login_attempts = {}
    register_attempts = {}
    app.state.llm_transport = llm_transport
    app.state.wechat_transport = wechat_transport
    app.state.qq_transport = qq_transport
    app.state.qq_connect = qq_connect

    @app.exception_handler(DomainError)
    async def domain_error(request, error):
        return JSONResponse({"code": error.code, "message": error.message}, status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def request_error(request, error):
        return JSONResponse({"code": "VALIDATION_ERROR", "message": "输入格式不正确，请检查必填项和时间", "field_errors": [str(e["loc"]) for e in error.errors()]}, status_code=422)

    # Snapshot payloads are large JSON; gzip cuts phone download size several
    # times over on slow links without changing any API shape.
    app.add_middleware(GZipMiddleware, minimum_size=1024)

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

    def owner(device=Depends(authenticated)):
        # Channels / assistant stay with the owner until P2 gives each account
        # its own channel binding; member accounts must not read owner data.
        tenancy.require_owner(store, device)
        return device

    def owner_desktop(device=Depends(owner)):
        if device["role"] != "desktop":
            raise DomainError("这项设置需要在电脑端操作", "DESKTOP_REQUIRED", 403)
        return device

    def user_of(device):
        return tenancy.user_id(store, device)

    def client_address(request: Request) -> str:
        address = request.client.host if request.client else "unknown"
        if address in ("127.0.0.1", "::1") and request.headers.get("cf-connecting-ip"):
            # Through the local Cloudflare tunnel every caller looks like localhost.
            address = request.headers["cf-connecting-ip"]
        return address

    def rate_limit(attempts: dict, key: str, limit: int = 10):
        window = [at for at in attempts.get(key, []) if clock() - at < timedelta(minutes=1)]
        if len(window) >= limit:
            raise DomainError("尝试过多，请一分钟后再试", "RATE_LIMITED", 429)
        attempts[key] = [*window, clock()]

    @app.get("/health")
    def health():
        latest = releases.read_latest(store.directory)
        return {"status": "ok", "version": version, "app_latest": latest["version"] if latest else None}

    # Release packages cannot write logcat, so the phone reports unexpected
    # client-side failures here; the desktop log is what we actually read.
    @app.post("/api/v1/client-log")
    async def client_log(data: dict, request: Request):
        entry = {
            "at": utcnow().isoformat(),
            "ip": client_address(request),
            "ua": request.headers.get("user-agent", "")[:200],
        }
        for key in ("source", "version", "platform", "message"):
            value = data.get(key)
            if isinstance(value, str):
                entry[key] = value[:4000]
        path = store.directory / "client_errors.log"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists() and path.stat().st_size > 4 * 1024 * 1024:
                path.replace(store.directory / "client_errors.old.log")
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except OSError:
            logging.getLogger("planner").warning("client log write failed", exc_info=True)
        return {"ok": True}

    # ---- Accounts (v2) ---------------------------------------------------
    @app.post("/api/v1/auth/login")
    def auth_login(data: auth.LoginIn, request: Request):
        rate_limit(login_attempts, client_address(request))
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            return auth.login(
                conn,
                data.username,
                data.password,
                device_name=data.device.name,
                platform=data.device.platform,
                now=clock(),
            )

    @app.post("/api/v1/auth/register")
    def auth_register(data: auth.RegisterIn, request: Request):
        rate_limit(register_attempts, client_address(request))
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            result = auth.register(
                conn,
                username=data.username,
                password=data.password,
                display_name=data.display_name,
                timezone_name=data.timezone or auth.DEFAULT_TIMEZONE,
                device_name=data.device.name,
                platform=data.device.platform,
                now=clock(),
            )
            # A fresh account needs its own state row before the client syncs.
            store.save(conn, store.initial_state(result["user"]["timezone"]), result["user"]["id"])
            return result

    @app.post("/api/v1/auth/logout")
    def auth_logout(device=Depends(authenticated)):
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("UPDATE devices SET revoked=1 WHERE id=?", (device["id"],))
        return {"ok": True}

    @app.get("/api/v1/me")
    def me(device=Depends(authenticated)):
        with store.connect() as conn:
            row = auth.get_user(conn, device["user_id"])
            if row is None:
                raise DomainError("账号不存在", "USER_NOT_FOUND", 404)
            return {"user": auth.public_user(row), "server_time": stamp(clock()), "server_version": version}

    @app.patch("/api/v1/me")
    def patch_me(data: auth.ProfilePatch, device=Depends(authenticated)):
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            user = auth.update_profile(
                conn,
                device["user_id"],
                display_name=data.display_name,
                timezone_name=data.timezone,
                onboarding=data.onboarding,
            )
            # The document carries its own copy of the zone (it decides day
            # boundaries and DST arithmetic), so changing the profile has to
            # keep it in step too.
            if data.timezone and data.timezone == user["timezone"]:
                state = store.state(conn, device["user_id"])
                if state["settings"].get("timezone") != data.timezone:
                    state["settings"]["timezone"] = data.timezone
                    state["revision"] += 1
                    store.save(conn, state, device["user_id"])
                    store.record_event(
                        conn, device["user_id"], state["revision"], device["id"],
                        "settings.update", {"timezone": data.timezone},
                    )
        return {"user": user}

    @app.post("/api/v1/me/password")
    def change_password(data: auth.PasswordChange, device=Depends(authenticated)):
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            auth.change_password(
                conn, device["user_id"], data.current_password, data.new_password,
                keep_device_id=device["id"],
            )
        return {"ok": True}

    @app.get("/api/v1/me/devices")
    def my_devices(device=Depends(authenticated)):
        with store.connect() as conn:
            return {"devices": auth.list_devices(conn, device["user_id"])}

    @app.delete("/api/v1/me/devices/{device_id}")
    def remove_device(device_id: str, device=Depends(authenticated)):
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            auth.revoke_device(conn, device["user_id"], device_id, keep_device_id=device["id"])
        return {"ok": True}

    @app.get("/api/v1/snapshot")
    def snapshot(device=Depends(authenticated)):
        user_id = user_of(device)
        expire_due(store, clock(), user_id)
        state = store.state(user_id=user_id)
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
        rate_limit(pairing_attempts, client_address(request))
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            entry = conn.execute("SELECT * FROM pairing WHERE code_hash=?", (digest(data.code),)).fetchone()
            if not entry or parse(entry["expires_at"]) <= clock():
                raise DomainError("配对码无效或已过期", "INVALID_PAIRING_CODE", 401)
            conn.execute("DELETE FROM pairing WHERE code_hash=?", (digest(data.code),))
            token, device_id = secrets.token_urlsafe(32), identifier()
            conn.execute(
                "INSERT INTO devices(id,name,role,token_hash,ack_revision,revoked,user_id,platform,"
                "created_at,last_seen_at) VALUES(?,?,?,?,0,0,?,?,?,?)",
                (device_id, data.name, "phone", digest(token), store.owner_id, "android",
                 stamp(clock()), stamp(clock())),
            )
        return {"device_id": device_id, "token": token}

    @app.get("/api/v1/devices")
    def devices(device=Depends(desktop)):
        with store.connect() as conn:
            rows = conn.execute(
                "SELECT id,name,role,revoked,ack_revision,platform,created_at,last_seen_at"
                " FROM devices WHERE user_id=?",
                (user_of(device),),
            )
            return [dict(row) for row in rows]

    @app.post("/api/v1/devices/{device_id}/revoke")
    def revoke(device_id: str, device=Depends(desktop)):
        if device_id == "desktop":
            raise DomainError("不能撤销当前电脑的启动凭证")
        with store.connect() as conn:
            result = conn.execute(
                "UPDATE devices SET revoked=1 WHERE id=? AND user_id=?",
                (device_id, user_of(device)),
            )
            if result.rowcount == 0:
                raise DomainError("设备不存在", status=404)
        return {"revoked": True}

    @app.post("/api/v1/plan/proposals")
    def plan_preview(data: PlanRequest, device=Depends(authenticated)):
        user_id = user_of(device)
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            state = store.state(conn, user_id)
            proposal = propose(state, data, clock())
            state["proposals"].append(proposal)
            store.save(conn, state, user_id)
        return proposal

    @app.post("/api/v1/operations")
    def mutate(operation: Operation, device=Depends(authenticated)):
        user_id = user_of(device)
        expire_due(store, clock(), user_id)
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                result = repo.apply(conn, user_id, device["id"], operation, clock())
            except ValidationError as error:
                raise DomainError("输入不符合要求：" + "; ".join(str(e["msg"]) for e in error.errors()), "VALIDATION_ERROR", 422) from None
        flush_archives(store, clock())
        return result

    @app.get("/api/v1/reports/{day}")
    def report(day: str, device=Depends(authenticated)):
        from datetime import date
        try:
            date.fromisoformat(day)
        except ValueError:
            raise DomainError("日期格式无效", status=422) from None
        return report_for(store.state(user_id=user_of(device)), day, clock())

    # ---- Assistant ------------------------------------------------------
    service = AssistantService(store, clock, lambda: app.state.llm_transport)
    app.state.assistant = service
    materials = MaterialService(service)
    app.state.materials = materials
    configs = service.configs

    def assistant_user(device):
        return user_of(device)

    @app.get("/api/v1/assistant/config")
    def assistant_config(device=Depends(authenticated)):
        user_id = assistant_user(device)
        with store.connect() as conn:
            return configs.public(conn, user_id, assistant.usage_today(conn, clock(), user_id))

    @app.post("/api/v1/assistant/config")
    def assistant_configure(data: assistant.AssistantConfigIn, device=Depends(authenticated)):
        user_id = assistant_user(device)
        with store.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            configs.update(conn, user_id, data)
            return configs.public(conn, user_id, assistant.usage_today(conn, clock(), user_id))

    @app.post("/api/v1/assistant/test")
    async def assistant_test(device=Depends(authenticated)):
        user_id = assistant_user(device)
        with store.connect() as conn:
            conf, key = service.require(conn, user_id)
            assistant.count_call(conn, clock(), user_id=user_id)
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
                # Do not rewrite the stored address behind the user's back: the app
                # shows the suggestion and the user decides (plan §11 P1).
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
    async def assistant_models(device=Depends(authenticated)):
        user_id = assistant_user(device)
        with store.connect() as conn:
            conf = configs.load(conn, user_id)
            key = configs.key(conn, user_id)[0]
        if not (conf["base_url"] and key):
            raise DomainError("先填写服务地址和 API Key", "ASSISTANT_NOT_CONFIGURED", 409)
        return {"models": await assistant.list_models(conf, key, app.state.llm_transport)}

    @app.get("/api/v1/assistant/messages")
    def assistant_history(device=Depends(authenticated)):
        user_id = assistant_user(device)
        with store.connect() as conn:
            return {"messages": assistant.message_rows(conn, user_id=user_id)}

    @app.post("/api/v1/assistant/messages")
    async def assistant_message(data: assistant.AssistantMessageIn, device=Depends(authenticated)):
        return {"messages": await service.converse(data.text, user_id=assistant_user(device))}

    @app.post("/api/v1/assistant/drafts/{draft_id}/apply")
    def assistant_apply(draft_id: str, device=Depends(authenticated)):
        return service.apply_draft(draft_id, device["id"], assistant_user(device))

    @app.post("/api/v1/assistant/drafts/{draft_id}/dismiss")
    def assistant_dismiss(draft_id: str, device=Depends(authenticated)):
        return service.dismiss_draft(draft_id, assistant_user(device))

    @app.post("/api/v1/assistant/drafts/{draft_id}/undo")
    def assistant_undo(draft_id: str, device=Depends(authenticated)):
        return service.undo_draft(draft_id, device["id"], assistant_user(device))

    # ---- Chat channels: WeChat official account + QQ official bot ------
    channel = WeChatChannel(store, clock, service, lambda: app.state.wechat_transport)
    qq = QQChannel(store, clock, service, lambda: app.state.qq_transport, app.state.qq_connect)
    app.state.wechat, app.state.qq = channel, qq
    # Reminders leave through QQ as soon as it is bound; WeChat keeps the job until then.
    outbound = RoutedChannel(channel, qq)
    app.state.proactive = Proactive(store, outbound, clock)
    app.state.weekly = WeeklyBrief(store, outbound, service, clock)
    channel.notification_valid = app.state.proactive.valid
    qq.notification_valid = app.state.proactive.valid

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
    def wechat_config(device=Depends(owner)):
        return channel.settings.public(device["role"] == "desktop")

    @app.post("/api/v1/wechat/config")
    def wechat_configure(data: WeChatConfigIn, device=Depends(owner_desktop)):
        channel.settings.update(data)
        return channel.settings.public(True)

    @app.post("/api/v1/wechat/bind-code")
    def wechat_bind_code(device=Depends(owner_desktop)):
        return channel.new_bind_code()

    @app.post("/api/v1/wechat/unbind")
    def wechat_unbind(device=Depends(owner_desktop)):
        return channel.unbind()

    @app.post("/api/v1/wechat/test")
    async def wechat_test(device=Depends(owner_desktop)):
        channel.enqueue("这是一条来自瞬时的测试消息。收到就说明电脑后台能给你发微信了。")
        if background:
            asyncio.create_task(channel.run_once())
        return {"queued": True}

    @app.get("/api/v1/wechat/outbox")
    def wechat_outbox(device=Depends(owner_desktop)):
        return {"messages": channel.outbox()}

    # ---- Chat identities: one WeChat/QQ handle per account -----------------
    identities = IdentityStore(store, clock)

    @app.post("/api/v1/channels/{channel}/bind-code")
    def channel_bind_code(channel: str, device=Depends(authenticated)):
        if channel not in CHANNELS:
            raise DomainError("暂时只支持微信和 QQ", "NOT_FOUND", 404)
        with store.connect() as conn:
            return identities.new_code(conn, channel, tenancy.user_id(store, device))

    @app.get("/api/v1/channels/bindings")
    def channel_bindings(device=Depends(authenticated)):
        with store.connect() as conn:
            return {"items": identities.bindings(conn, tenancy.user_id(store, device))}

    @app.delete("/api/v1/channels/{channel}/binding")
    def channel_unbind(channel: str, device=Depends(authenticated)):
        if channel not in CHANNELS:
            raise DomainError("暂时只支持微信和 QQ", "NOT_FOUND", 404)
        user_id = tenancy.user_id(store, device)
        with store.connect() as conn:
            rows = conn.execute("SELECT external_id FROM channel_identities WHERE channel=? AND user_id=?",
                                (channel, user_id)).fetchall()
            for row in rows:
                identities.unbind(conn, channel, row["external_id"], user_id)
        return {"unbound": len(rows)}

    # ---- QQ official-bot channel -----------------------------------------
    @app.get("/api/v1/qq/config")
    def qq_config(device=Depends(owner)):
        return {**qq.settings.public(device["role"] == "desktop"), **qq.status()}

    @app.post("/api/v1/qq/config")
    def qq_configure(data: QQConfigIn, device=Depends(owner_desktop)):
        qq.settings.update(data)
        return {**qq.settings.public(True), **qq.status()}

    @app.post("/api/v1/qq/bind-code")
    def qq_bind_code(device=Depends(owner_desktop)):
        return qq.new_bind_code()

    @app.post("/api/v1/qq/unbind")
    def qq_unbind(device=Depends(owner_desktop)):
        return qq.unbind()

    @app.post("/api/v1/qq/test")
    async def qq_test(device=Depends(owner_desktop)):
        qq.enqueue("这是一条来自瞬时的测试消息。收到就说明电脑后台能通过 QQ 找到你了。")
        if background:
            asyncio.create_task(qq.run_once())
        return {"queued": True}

    @app.get("/api/v1/qq/outbox")
    def qq_outbox(device=Depends(owner_desktop)):
        return {"messages": qq.outbox()}

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
            return await asyncio.to_thread(materials.upload, name, day, description, external_allowed, bytes(content),
                                            tenancy.user_id(store, device))
        except ValueError:
            raise DomainError('日期格式无效', status=422) from None

    @app.post('/api/v1/reviews/generate')
    async def generate_review(data: GenerateReview, device=Depends(authenticated)):
        try:
            return await materials.generate(data, tenancy.user_id(store, device))
        except ValueError:
            raise DomainError('日期或材料格式无效', status=422) from None

    # ---- Phone app releases (published by tools/release.ps1) -------------
    @app.get("/api/v1/app/latest")
    def app_latest():
        latest = releases.read_latest(store.directory)
        if not latest:
            raise DomainError("电脑上还没有发布手机版安装包", "NO_RELEASE", 404)
        return releases.public(latest)

    @app.get("/api/v1/app/download")
    def app_download(request: Request):
        latest = releases.read_latest(store.directory)
        if not latest:
            raise DomainError("电脑上还没有发布手机版安装包", "NO_RELEASE", 404)
        path = releases.apk_path(store.directory, latest)
        size = path.stat().st_size
        start, end, partial = 0, size - 1, False
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", request.headers.get("range", "").strip())
        if match:
            start = int(match.group(1))
            end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
            if start >= size or end < start:
                return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
            partial = True
        length = end - start + 1

        def chunks():
            # Files are megabytes, so stream in blocks; seek() lets a phone that
            # lost Wi-Fi resume from the byte it already has (client sends Range).
            with path.open("rb") as stream:
                stream.seek(start)
                remaining = length
                while remaining > 0:
                    block = stream.read(min(1 << 20, remaining))
                    if not block:
                        break
                    remaining -= len(block)
                    yield block

        headers = {"Accept-Ranges": "bytes", "Content-Length": str(length),
                   "X-Timer-Sha256": latest["sha256"], "X-Timer-Version": latest["version"]}
        if partial:
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        return StreamingResponse(chunks(), status_code=206 if partial else 200,
                                 media_type="application/vnd.android.package-archive",
                                 headers=headers)

    return app


app = create_app()
