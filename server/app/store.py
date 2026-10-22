"""SQLite transactions retain accepted operations and immutable event history.

v2 layout: there is one owner account (the person who set the server up) plus
any number of members; each account has a JSON document in ``user_state`` and
an append-only ``user_events`` log.  The v1 tables (``document``, ``events``,
``operations``) stay for compatibility: the owner mirrors into them and the
desktop token / pairing code still authenticate as the owner.
"""
import hashlib
import json
import secrets
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from . import db as schema

LEGACY_SCHEMA = """
    CREATE TABLE IF NOT EXISTS document (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, device_id TEXT NOT NULL, request_hash TEXT NOT NULL, response TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS events (revision INTEGER PRIMARY KEY, device_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, recorded_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, ack_revision INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS pairing (code_hash TEXT PRIMARY KEY, expires_at TEXT NOT NULL);
"""


def utcnow():
    return datetime.now(timezone.utc)


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def initial_state():
    return {
        "revision": 0,
        # Categories are the user's own; nothing is pre-filled.
        "projects": [], "sleeps": [],
        "settings": {"timezone": "America/Los_Angeles", "day_start": "09:00", "day_end": "22:00", "daily_review_time": "21:30", "auto_adjust": True},
        "tasks": [], "blocks": [], "sessions": [], "feedbacks": [],
        "waiting_checks": [], "reviews": [], "proposals": [], "jobs": [],
    }


def _now_stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Store:
    def __init__(self, directory: Path):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "planner.db"
        with self.connect() as conn:
            conn.executescript(LEGACY_SCHEMA)
            conn.execute("INSERT OR IGNORE INTO document VALUES(1,?)", (encode(initial_state()),))
            schema.migrate(conn)
            self.owner_id = self._bootstrap_owner(conn)
        credential = directory / "desktop-token"
        if credential.exists():
            self.desktop_token = credential.read_text().strip()
        else:
            self.desktop_token = secrets.token_urlsafe(32)
            # The file is local bootstrap configuration, never printed or served as static content.
            credential.write_text(self.desktop_token, encoding="utf-8")
        with self.connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO devices(id,name,role,token_hash,ack_revision,revoked,"
                "user_id,platform,created_at,last_seen_at) VALUES(?,?,?,?,0,0,?,?,?,?)",
                ("desktop", "这台电脑", "desktop", digest(self.desktop_token), self.owner_id,
                 "windows", _now_stamp(), _now_stamp()),
            )
            conn.execute("UPDATE devices SET user_id=? WHERE user_id IS NULL", (self.owner_id,))

    @staticmethod
    def initial_state():
        return initial_state()

    @staticmethod
    def _bootstrap_owner(conn) -> str:
        """Create the owner account from the legacy single-user document once."""
        from . import auth  # imported lazily: auth -> domain -> models, no cycle back here

        row = conn.execute(
            "SELECT * FROM users ORDER BY (role='admin') DESC, created_at LIMIT 1"
        ).fetchone()
        if row is not None:
            return row["id"]
        legacy = json.loads(conn.execute("SELECT body FROM document WHERE id=1").fetchone()[0])
        owner_id = str(uuid.uuid4())
        zone = legacy.get("settings", {}).get("timezone", "America/Los_Angeles")
        conn.execute(
            "INSERT INTO users(id, username, password_hash, display_name, role, status,"
            " timezone, onboarding, created_at) VALUES(?,?,?,?,?,'active',?,?,?)",
            (
                owner_id,
                "me",
                # A random unused password: the owner gets in with the desktop token
                # or by running `python -m app.admin user reset-password --username me`.
                auth.hash_password(secrets.token_urlsafe(24)),
                "我",
                "admin",
                zone,
                json.dumps({"version": 2, "step": 0, "done": [], "skipped": []}),
                _now_stamp(),
            ),
        )
        conn.execute(
            "INSERT OR IGNORE INTO user_state(user_id, body, revision, size_bytes, updated_at)"
            " SELECT ?, body, 0, length(body), ? FROM document WHERE id=1",
            (owner_id, _now_stamp()),
        )
        return owner_id

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.path, timeout=15)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA busy_timeout=15000")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def state(self, conn=None, user_id=None):
        user_id = user_id or self.owner_id
        if conn is not None:
            row = conn.execute("SELECT body FROM user_state WHERE user_id=?", (user_id,)).fetchone()
            if row is not None:
                return json.loads(row["body"])
            if user_id == self.owner_id:
                # v1 rows migrated before user_state existed; fall back rather than 500.
                return json.loads(conn.execute("SELECT body FROM document WHERE id=1").fetchone()[0])
            state = initial_state()
            body = encode(state)
            conn.execute(
                "INSERT OR IGNORE INTO user_state(user_id, body, revision, size_bytes, updated_at)"
                " VALUES(?,?,0,?,?)",
                (user_id, body, len(body.encode("utf-8")), _now_stamp()),
            )
            return state
        with self.connect() as db:
            return self.state(db, user_id)

    def save(self, conn, state, user_id=None):
        user_id = user_id or self.owner_id
        body = encode(state)
        conn.execute(
            "INSERT INTO user_state(user_id, body, revision, size_bytes, updated_at)"
            " VALUES(?,?,?,?,?)"
            " ON CONFLICT(user_id) DO UPDATE SET body=excluded.body, revision=excluded.revision,"
            " size_bytes=excluded.size_bytes, updated_at=excluded.updated_at",
            (user_id, body, state.get("revision", 0), len(body.encode("utf-8")), _now_stamp()),
        )
        if user_id == self.owner_id:  # keep the legacy document in sync
            conn.execute("UPDATE document SET body=? WHERE id=1", (body,))

    def record_event(self, conn, user_id, revision, device_id, kind, payload, now=None):
        recorded = (now or utcnow()).astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        conn.execute(
            "INSERT INTO user_events(user_id, revision, device_id, kind, payload, recorded_at)"
            " VALUES(?,?,?,?,?,?)",
            (user_id, revision, device_id, kind, encode(payload), recorded),
        )
        if user_id == self.owner_id:  # proactive notifications still read the legacy log
            conn.execute(
                "INSERT INTO events VALUES(?,?,?,?,?)",
                (revision, device_id, kind, encode(payload), recorded),
            )

    def authenticate(self, token):
        from . import auth

        if not token:
            return None
        with self.connect() as conn:
            return auth.resolve_token(conn, token)
