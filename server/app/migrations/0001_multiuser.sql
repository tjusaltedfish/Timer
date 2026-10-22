-- 0001: multi-user core (users, per-user state, per-user events).
-- Legacy single-user tables (document/operations/devices/pairing/events) stay
-- in place; the columns the v2 code needs are added by db.migrate's
-- ensure-column step because SQLite has no "ADD COLUMN IF NOT EXISTS".

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL COLLATE NOCASE UNIQUE,
    password_hash TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'member',      -- admin / member
    status        TEXT NOT NULL DEFAULT 'active',      -- active / disabled
    timezone      TEXT NOT NULL DEFAULT 'America/Los_Angeles',
    onboarding    TEXT NOT NULL DEFAULT '{"version":2,"step":0,"done":[],"skipped":[]}',
    created_at    TEXT NOT NULL,
    last_login_at TEXT
);

CREATE TABLE IF NOT EXISTS user_state (
    user_id    TEXT PRIMARY KEY,
    body       TEXT NOT NULL,
    revision   INTEGER NOT NULL DEFAULT 0,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS user_events (
    user_id     TEXT NOT NULL,
    revision    INTEGER NOT NULL,
    device_id   TEXT NOT NULL,
    kind        TEXT NOT NULL,
    payload     TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    PRIMARY KEY (user_id, revision)
);

CREATE INDEX IF NOT EXISTS user_events_recorded ON user_events(user_id, recorded_at);
