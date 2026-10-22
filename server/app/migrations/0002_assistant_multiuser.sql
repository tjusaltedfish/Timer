-- v2 P2: per-user assistant configuration, encrypted API keys, usage and
-- clarification questions.  The legacy v1 tables stay in place; new columns
-- and rows are added by `assistant.ensure_schema` so old databases migrate in
-- place without losing the owner's history.

CREATE TABLE IF NOT EXISTS assistant_configs (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    base_url TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    daily_limit INTEGER NOT NULL DEFAULT 200,
    timeout_seconds INTEGER NOT NULL DEFAULT 45,
    confirm_first INTEGER NOT NULL DEFAULT 0,
    persona TEXT NOT NULL DEFAULT '大肥鱼',
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS assistant_keys (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    cipher TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS assistant_usage_by_user (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day TEXT NOT NULL,
    calls INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, day)
);

CREATE TABLE IF NOT EXISTS assistant_questions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    answered_at TEXT
);

CREATE INDEX IF NOT EXISTS assistant_questions_user ON assistant_questions(user_id, created_at);
