"""Accounts, passwords, devices and bearer tokens (v2).

Password hashes are self-describing strings:

* ``$argon2id$...`` from argon2-cffi (installed by ``requirements-v2.txt``);
* ``scrypt$<n>$<r>$<p>$<salt_b64>$<hash_b64>`` from the stdlib when the
  optional dependency is missing, so the server still starts and old test
  environments keep working. ``verify_password`` accepts both formats, which
  also lets an existing scrypt hash be upgraded on the next password change.

Device tokens follow the v1 convention: a random URL-safe secret is shown to
the client once, only its SHA-256 digest is stored.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import uuid
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from .domain import DomainError

USERNAME = re.compile(r"^[A-Za-z0-9_-]{2,24}$")
MIN_PASSWORD = 10
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2**14, 8, 1

try:  # optional; see requirements-v2.txt
    from argon2 import PasswordHasher
    from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

    _ARGON = PasswordHasher()
except ImportError:  # pragma: no cover - exercised by the stdlib fallback
    _ARGON = None
    InvalidHashError = ValueError  # type: ignore[assignment,misc]
    VerificationError = ValueError  # type: ignore[assignment,misc]
    VerifyMismatchError = ValueError  # type: ignore[assignment,misc]


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _unb64(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))


def _scrypt_hash(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, dklen=32
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${_b64(salt)}${_b64(digest)}"


def hash_password(password: str) -> str:
    if _ARGON is not None:
        return _ARGON.hash(password)
    return _scrypt_hash(password)


def verify_password(stored: str, password: str) -> bool:
    if stored.startswith("$argon2"):
        if _ARGON is None:  # hash was created on a machine with argon2 installed
            return False
        try:
            return _ARGON.verify(stored, password)
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False
    if not stored.startswith("scrypt$"):
        return False
    try:
        _, n, r, p, salt_b64, digest_b64 = stored.split("$")
        digest = hashlib.scrypt(
            password.encode("utf-8"),
            salt=_unb64(salt_b64),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(_unb64(digest_b64)),
        )
        return hmac.compare_digest(_b64(digest), digest_b64)
    except (ValueError, TypeError):
        return False


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def validate_username(username: str) -> str:
    if not USERNAME.match(username):
        raise DomainError("用户名用 2–24 位字母、数字、下划线或短横线", "INVALID_USERNAME", 422)
    return username


def validate_timezone(name: str) -> str:
    try:
        ZoneInfo(name)
    except (ValueError, KeyError):
        raise DomainError("不认识这个时区", "INVALID_TIMEZONE", 422) from None
    return name


def validate_password(password: str) -> str:
    if len(password) < MIN_PASSWORD:
        raise DomainError(f"密码至少 {MIN_PASSWORD} 位", "WEAK_PASSWORD", 422)
    if len(password) > 200:
        raise DomainError("密码太长了", "WEAK_PASSWORD", 422)
    return password


def _stamp(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def public_user(row) -> dict:
    onboarding = row["onboarding"]
    try:
        onboarding = json.loads(onboarding) if isinstance(onboarding, str) else onboarding
    except ValueError:
        onboarding = {"version": 2, "step": 0, "done": [], "skipped": []}
    return {
        "id": row["id"],
        "username": row["username"],
        "display_name": row["display_name"],
        "role": row["role"],
        "timezone": row["timezone"],
        "onboarding": onboarding,
        "created_at": row["created_at"],
        "last_login_at": row["last_login_at"],
    }


def find_user(conn, username: str):
    return conn.execute(
        "SELECT * FROM users WHERE username = ? COLLATE NOCASE", (username,)
    ).fetchone()


def get_user(conn, user_id: str):
    return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def user_count(conn) -> int:
    return conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]


def create_user(
    conn,
    *,
    username: str,
    password: str,
    display_name: str = "",
    timezone_name: str = "America/Los_Angeles",
    role: str = "member",
    now: datetime | None = None,
) -> dict:
    validate_username(username)
    validate_password(password)
    validate_timezone(timezone_name)  # rejects a bad zone before anything is written
    user_id = str(uuid.uuid4())
    created = _stamp(now or datetime.now(timezone.utc))
    try:
        conn.execute(
            "INSERT INTO users(id, username, password_hash, display_name, role, status,"
            " timezone, onboarding, created_at) VALUES(?,?,?,?,?,'active',?,?,?)",
            (
                user_id,
                username,
                hash_password(password),
                display_name.strip() or username,
                role,
                timezone_name,
                json.dumps({"version": 2, "step": 0, "done": [], "skipped": []}),
                created,
            ),
        )
    except Exception as error:  # unique constraint -> friendly, non-leaky message
        if "UNIQUE" in str(error).upper():
            raise DomainError("这个用户名已经有人用了", "USERNAME_TAKEN", 409) from None
        raise
    return public_user(get_user(conn, user_id))


def issue_device(
    conn,
    user_id: str,
    name: str = "",
    platform: str = "android",
    now: datetime | None = None,
) -> tuple[dict, str]:
    token = secrets.token_urlsafe(32)
    role = "desktop" if platform in ("windows", "macos", "linux") else "phone"
    device_id = str(uuid.uuid4())
    created = _stamp(now or datetime.now(timezone.utc))
    conn.execute(
        "INSERT INTO devices(id, name, role, token_hash, ack_revision, revoked,"
        " user_id, platform, created_at, last_seen_at) VALUES(?,?,?,?,0,0,?,?,?,?)",
        (device_id, name.strip() or "新设备", role, hash_token(token), user_id, platform, created, created),
    )
    device = dict(
        conn.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
    )
    return device, token


def public_device(row) -> dict:
    keys = ("id", "name", "role", "platform", "created_at", "last_seen_at")
    data = dict(row)
    return {key: data.get(key) for key in keys}


def login(
    conn,
    username: str,
    password: str,
    *,
    device_name: str = "",
    platform: str = "android",
    now: datetime | None = None,
) -> dict:
    row = find_user(conn, username)
    if row is None or row["status"] != "active" or not verify_password(row["password_hash"], password):
        raise DomainError("用户名或密码不对", "AUTH_FAILED", 401)
    moment = now or datetime.now(timezone.utc)
    conn.execute("UPDATE users SET last_login_at = ? WHERE id = ?", (_stamp(moment), row["id"]))
    device, token = issue_device(conn, row["id"], device_name, platform, moment)
    return {"token": token, "device": public_device(device), "user": public_user(row)}


# ---- Request bodies (kept here so the auth surface stays in one module) ----
from pydantic import BaseModel, ConfigDict, Field  # noqa: E402  (public API below)


class DeviceIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(default="", max_length=40)
    platform: str = Field(default="android", pattern="^(windows|macos|linux|android|ios)$")


class LoginIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=1, max_length=200)
    device: DeviceIn = Field(default_factory=DeviceIn)


class ProfilePatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    display_name: str | None = Field(default=None, max_length=40)
    timezone: str | None = Field(default=None, max_length=64)
    onboarding: dict | None = None


class PasswordChange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    current_password: str = Field(min_length=1, max_length=200)
    new_password: str = Field(min_length=1, max_length=200)


class RegisterIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=1, max_length=200)
    display_name: str = Field(default="", max_length=40)
    timezone: str | None = Field(default=None, max_length=64)
    device: DeviceIn = Field(default_factory=DeviceIn)


def resolve_token(conn, token: str, now: datetime | None = None) -> dict | None:
    if not token:
        return None
    row = conn.execute(
        "SELECT d.*, u.id AS user_id, u.username, u.display_name, u.role AS user_role,"
        " u.status AS user_status, u.timezone AS user_timezone, u.onboarding AS user_onboarding"
        " FROM devices d JOIN users u ON u.id = d.user_id"
        " WHERE d.token_hash = ? AND d.revoked = 0",
        (hash_token(token),),
    ).fetchone()
    if row is None or row["user_status"] != "active":
        return None
    device = dict(row)
    # a write per request would serialize readers; refresh at most once a minute
    moment = now or datetime.now(timezone.utc)
    seen = device.get("last_seen_at")
    try:
        stale = seen is None or (moment - datetime.fromisoformat(seen.replace("Z", "+00:00"))).total_seconds() > 60
    except ValueError:
        stale = True
    if stale:
        conn.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", (_stamp(moment), device["id"]))
    return device


def update_profile(
    conn,
    user_id: str,
    *,
    display_name: str | None = None,
    timezone_name: str | None = None,
    onboarding: dict | None = None,
) -> dict:
    row = get_user(conn, user_id)
    if row is None:
        raise DomainError("账号不存在", "USER_NOT_FOUND", 404)
    if display_name is not None:
        name = display_name.strip()
        if not 1 <= len(name) <= 40:
            raise DomainError("显示名要 1–40 个字", "INVALID_DISPLAY_NAME", 422)
        conn.execute("UPDATE users SET display_name = ? WHERE id = ?", (name, user_id))
    if timezone_name is not None:
        validate_timezone(timezone_name)
        conn.execute("UPDATE users SET timezone = ? WHERE id = ?", (timezone_name, user_id))
    if onboarding is not None:
        if not isinstance(onboarding, dict):
            raise DomainError("onboarding 必须是对象", "INVALID_ONBOARDING", 422)
        conn.execute(
            "UPDATE users SET onboarding = ? WHERE id = ?",
            (json.dumps(onboarding, ensure_ascii=False), user_id),
        )
    return public_user(get_user(conn, user_id))


def change_password(conn, user_id: str, current: str, new: str, keep_device_id: str | None = None) -> None:
    row = get_user(conn, user_id)
    if row is None:
        raise DomainError("账号不存在", "USER_NOT_FOUND", 404)
    if not verify_password(row["password_hash"], current):
        raise DomainError("当前密码不对", "AUTH_FAILED", 401)
    validate_password(new)
    conn.execute(
        "UPDATE users SET password_hash = ? WHERE id = ?", (hash_password(new), user_id)
    )
    if keep_device_id:
        conn.execute(
            "UPDATE devices SET revoked = 1 WHERE user_id = ? AND id != ?", (user_id, keep_device_id)
        )


def list_devices(conn, user_id: str) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM devices WHERE user_id = ? ORDER BY created_at DESC", (user_id,)
    ).fetchall()
    return [
        {
            "id": row["id"],
            "name": row["name"],
            "platform": row["platform"],
            "role": row["role"],
            "created_at": row["created_at"],
            "last_seen_at": row["last_seen_at"],
            "revoked": bool(row["revoked"]),
        }
        for row in rows
    ]


def revoke_device(conn, user_id: str, device_id: str, keep_device_id: str | None = None) -> None:
    row = conn.execute(
        "SELECT * FROM devices WHERE id = ? AND user_id = ?", (device_id, user_id)
    ).fetchone()
    if row is None:
        raise DomainError("没有这个设备", "DEVICE_NOT_FOUND", 404)
    if keep_device_id == device_id:
        raise DomainError("不能把当前正在用的设备下线", "CANNOT_REVOKE_SELF", 409)
    conn.execute("UPDATE devices SET revoked = 1 WHERE id = ?", (device_id,))


# ---- Self-service registration (v2.1) ---------------------------------------
REGISTRATION_KEY = "allow_registration"
DEFAULT_TIMEZONE = "Asia/Shanghai"


def registration_open(conn) -> bool:
    """True when the owner opened sign-ups from the admin console."""
    row = conn.execute(
        "SELECT value FROM app_config WHERE key = ?", (REGISTRATION_KEY,)
    ).fetchone()
    return row is not None and str(row["value"]).strip().lower() in ("on", "true", "1")


def set_registration(conn, allowed: bool) -> None:
    conn.execute(
        "INSERT INTO app_config(key, value) VALUES(?, ?)"
        " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (REGISTRATION_KEY, "on" if allowed else "off"),
    )


def register(
    conn,
    *,
    username: str,
    password: str,
    display_name: str = "",
    timezone_name: str = DEFAULT_TIMEZONE,
    device_name: str = "",
    platform: str = "android",
    now: datetime | None = None,
) -> dict:
    """Create an account and sign it in.

    A server with zero accounts always accepts its first registrant and makes
    them the owner; after that sign-ups need the ``allow_registration`` switch
    (or the admin CLI) so a stray visitor cannot create accounts.
    """
    if user_count(conn) == 0:
        role = "admin"
    elif registration_open(conn):
        role = "member"
    else:
        raise DomainError("这个服务器没开注册，请让站长开一下，或用站长开的账号", "REGISTRATION_CLOSED", 403)
    create_user(
        conn,
        username=username,
        password=password,
        display_name=display_name,
        timezone_name=timezone_name,
        role=role,
        now=now,
    )
    return login(
        conn,
        username,
        password,
        device_name=device_name,
        platform=platform,
        now=now,
    )


def merge_user_data(conn, directory: Path | str, source_id: str, target_id: str) -> dict:
    """Move everything one account owns onto another (one-off owner transfer).

    Used when someone registers a fresh account and wants their existing
    data: every table with a ``user_id`` column is re-pointed with
    ``UPDATE OR REPLACE`` (so user-keyed rows such as the state document and
    the assistant config replace the target's blank ones), material files move
    directories, the source account is disabled and the target becomes admin.
    """
    if source_id == target_id:
        raise DomainError("源账号和目标账号是同一个", "INVALID_MERGE", 422)
    if get_user(conn, source_id) is None or get_user(conn, target_id) is None:
        raise DomainError("账号不存在", "USER_NOT_FOUND", 404)
    moved: dict[str, int] = {}
    tables = [
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        if row["name"] not in ("users", "sqlite_sequence")
    ]
    for table in tables:
        columns = [row["name"] for row in conn.execute(f"PRAGMA table_info({table})")]
        if "user_id" not in columns:
            continue
        count = conn.execute(
            f"UPDATE OR REPLACE {table} SET user_id = ? WHERE user_id = ?",
            (target_id, source_id),
        ).rowcount
        if count:
            moved[table] = count
    root = Path(directory)
    source_dir = root / "materials" / source_id
    target_dir = root / "materials" / target_id
    if source_dir.is_dir():
        target_dir.mkdir(parents=True, exist_ok=True)
        for item in source_dir.iterdir():
            item.replace(target_dir / item.name)
        source_dir.rmdir()
        moved["materials_files"] = 1
    conn.execute("UPDATE devices SET revoked = 1 WHERE user_id = ?", (source_id,))
    conn.execute("UPDATE users SET role = 'admin' WHERE id = ?", (target_id,))
    conn.execute("UPDATE users SET status = 'disabled' WHERE id = ?", (source_id,))
    return moved

