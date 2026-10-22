"""SQLite access: WAL, BEGIN IMMEDIATE, and ordered schema migrations.

The database is one file; every request opens its own connection (SQLite is
cheap here) and closes it when the request is done.  Multi-user correctness
relies on two rules:

* writes go through ``Write`` (``BEGIN IMMEDIATE``) so two writers queue
  instead of racing; ``busy_timeout`` covers the 3-person load;
* migrations are plain SQL files in :mod:`app.migrations`, applied in name
  order and recorded in ``schema_version``.  Every statement is idempotent
  (``IF NOT EXISTS``) so a crash mid-migration can be retried safely.
"""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).with_name("migrations")
BUSY_TIMEOUT_MS = 15000


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def stamp(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def connect(path: Path | str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=BUSY_TIMEOUT_MS / 1000)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
    return conn


@contextmanager
def session(path: Path | str):
    """Connection with commit-on-success / rollback-on-error."""
    conn = connect(path)
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def write(conn: sqlite3.Connection):
    """Exclusive write transaction; the caller already owns ``conn``."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def migrations() -> list[tuple[int, str]]:
    found = []
    for script in sorted(MIGRATIONS_DIR.glob("*.sql")):
        try:
            version = int(script.name.split("_", 1)[0])
        except ValueError:  # pragma: no cover - a misnamed file is a bug, not user input
            raise RuntimeError(f"migration name must start with a version: {script.name}") from None
        found.append((version, script.read_text(encoding="utf-8")))
    return found


def migrate(conn: sqlite3.Connection) -> list[int]:
    """Apply every migration not yet recorded in ``schema_version``."""
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_version ("
        " version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
    )
    applied = {row[0] for row in conn.execute("SELECT version FROM schema_version")}
    ran: list[int] = []
    for version, sql in migrations():
        if version in applied:
            continue
        conn.executescript(sql)
        conn.execute(
            "INSERT OR IGNORE INTO schema_version(version, applied_at) VALUES(?,?)",
            (version, stamp(utcnow())),
        )
        ran.append(version)
    _ensure_columns(conn)
    return ran


# Columns added to the legacy tables after v1.  Kept here (instead of in SQL)
# because SQLite refuses "ADD COLUMN IF NOT EXISTS"; the check is idempotent.
LEGACY_COLUMNS = (
    ("devices", "user_id", "TEXT"),
    ("devices", "platform", "TEXT"),
    ("devices", "created_at", "TEXT"),
    ("devices", "last_seen_at", "TEXT"),
    ("operations", "user_id", "TEXT"),
)


def _ensure_columns(conn: sqlite3.Connection) -> None:
    for table, column, decl in LEGACY_COLUMNS:
        existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if not existing:  # table not created yet; Store creates it right after
            continue
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS operations_user ON operations(user_id, id)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id)"
    )
