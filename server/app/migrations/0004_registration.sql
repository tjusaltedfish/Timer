-- 0004: self-service registration (v2.1).
-- The server keeps a tiny key/value switch table for runtime toggles; the only
-- key today is `allow_registration`, turned on from the admin CLI while a
-- friend signs up. A brand-new server (zero accounts) is always open so its
-- first visitor becomes the owner without shell access.

CREATE TABLE IF NOT EXISTS app_config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
