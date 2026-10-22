-- Map one chat handle (WeChat openid, QQ openid) to one 瞬时 account.
CREATE TABLE IF NOT EXISTS channel_identities (
    channel TEXT NOT NULL,
    external_id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    display_name TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    PRIMARY KEY (channel, external_id)
);
CREATE INDEX IF NOT EXISTS channel_identities_user ON channel_identities(user_id);

-- Short-lived one-time codes a logged-in person reads in the app and sends to the bot.
CREATE TABLE IF NOT EXISTS channel_bind_codes (
    code TEXT PRIMARY KEY,
    channel TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);
CREATE INDEX IF NOT EXISTS channel_bind_codes_user ON channel_bind_codes(channel, user_id);
