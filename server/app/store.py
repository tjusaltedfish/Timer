"""SQLite transactions retain accepted operations and immutable event history."""
import hashlib
import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path


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


class Store:
    def __init__(self, directory: Path):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "planner.db"
        with self.connect() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS document (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, device_id TEXT NOT NULL, request_hash TEXT NOT NULL, response TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (revision INTEGER PRIMARY KEY, device_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, recorded_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, ack_revision INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS pairing (code_hash TEXT PRIMARY KEY, expires_at TEXT NOT NULL);
            """)
            conn.execute("INSERT OR IGNORE INTO document VALUES(1,?)", (encode(initial_state()),))
        credential = directory / "desktop-token"
        if credential.exists():
            self.desktop_token = credential.read_text().strip()
        else:
            self.desktop_token = secrets.token_urlsafe(32)
            # The file is local bootstrap configuration, never printed or served as static content.
            credential.write_text(self.desktop_token, encoding="utf-8")
        with self.connect() as conn:
            conn.execute("INSERT OR IGNORE INTO devices(id,name,role,token_hash) VALUES(?,?,?,?)",
                         ("desktop", "这台电脑", "desktop", digest(self.desktop_token)))

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.path, timeout=15)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def state(self, conn=None):
        if conn is not None:
            return json.loads(conn.execute("SELECT body FROM document WHERE id=1").fetchone()[0])
        with self.connect() as db:
            return self.state(db)

    def save(self, conn, state):
        conn.execute("UPDATE document SET body=? WHERE id=1", (encode(state),))

    def authenticate(self, token):
        with self.connect() as conn:
            device = conn.execute("SELECT id,name,role,revoked,ack_revision FROM devices WHERE token_hash=?", (digest(token),)).fetchone()
            return dict(device) if device and not device["revoked"] else None
