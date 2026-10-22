"""Who is talking: map one chat handle to one 瞬时 account.

A WeChat official account is shared by everyone who follows it, so the openid
in a push is the only identity the server gets. Each openid is bound, once, to
a local account with a short one-time code the person reads in the app. The
binding is what keeps one person's chat commands away from another person's
schedule.
"""
import secrets
import string
from datetime import timedelta

from .domain import parse, stamp

CODE_TTL = timedelta(minutes=10)
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"  # no look-alikes: 0/O, 1/I/L
CHANNELS = ("wechat", "qq")


class IdentityStore:
    def __init__(self, store, clock):
        self.store, self.clock = store, clock

    # ---- Lookup ----------------------------------------------------------
    def user_of(self, conn, channel, external_id):
        row = conn.execute("SELECT user_id FROM channel_identities WHERE channel=? AND external_id=?",
                           (channel, external_id)).fetchone()
        return row["user_id"] if row else None

    def touch(self, conn, channel, external_id):
        conn.execute("UPDATE channel_identities SET last_seen_at=? WHERE channel=? AND external_id=?",
                     (stamp(self.clock()), channel, external_id))

    # ---- Binding ---------------------------------------------------------
    def bind(self, conn, channel, external_id, user_id, display_name=None):
        now = stamp(self.clock())
        conn.execute("INSERT OR REPLACE INTO channel_identities"
                     "(channel, external_id, user_id, display_name, created_at, last_seen_at) "
                     "VALUES(?,?,?,?,COALESCE((SELECT created_at FROM channel_identities"
                     " WHERE channel=? AND external_id=?), ?),?)",
                     (channel, external_id, user_id, display_name, channel, external_id, now, now))

    def other_user_of(self, conn, channel, external_id, user_id):
        """True when this handle already belongs to somebody else."""
        current = self.user_of(conn, channel, external_id)
        return current is not None and current != user_id

    def unbind(self, conn, channel, external_id, user_id):
        row = conn.execute("SELECT user_id FROM channel_identities WHERE channel=? AND external_id=?",
                           (channel, external_id)).fetchone()
        if not row or row["user_id"] != user_id:
            return False
        conn.execute("DELETE FROM channel_identities WHERE channel=? AND external_id=?", (channel, external_id))
        return True

    def bindings(self, conn, user_id):
        rows = conn.execute("SELECT channel, external_id, display_name, created_at, last_seen_at "
                            "FROM channel_identities WHERE user_id=? ORDER BY created_at", (user_id,)).fetchall()
        return [{**dict(row), "hint": "····" + row["external_id"][-4:]} for row in rows]

    # ---- One-time codes --------------------------------------------------
    def new_code(self, conn, channel, user_id):
        now = self.clock()
        conn.execute("DELETE FROM channel_bind_codes WHERE expires_at<=? OR used_at IS NOT NULL", (stamp(now),))
        for _ in range(8):  # codes are tiny; collisions are rare but possible
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))
            try:
                conn.execute("INSERT INTO channel_bind_codes(code, channel, user_id, created_at, expires_at) "
                             "VALUES(?,?,?,?,?)",
                             (code, channel, user_id, stamp(now), stamp(now + CODE_TTL)))
                return {"code": code, "channel": channel, "expires_at": stamp(now + CODE_TTL)}
            except Exception:  # noqa: BLE001 - duplicate primary key; try another code
                continue
        raise RuntimeError("could not allocate a bind code")

    def redeem(self, conn, channel, code, external_id, display_name=None):
        """Returns (user_id, None) on success, or (None, human message) on failure."""
        now = self.clock()
        code = (code or "").strip().upper()
        row = conn.execute("SELECT * FROM channel_bind_codes WHERE code=?", (code,)).fetchone()
        if not row or row["channel"] != channel:
            return None, "这个绑定码不对，请检查有没有发错或发漏。"
        if row["used_at"]:
            return None, "这个绑定码已经用过了，请重新生成一个。"
        if parse(row["expires_at"]) <= now:
            return None, "这个绑定码已经过期了，请重新生成一个。"
        current = self.user_of(conn, channel, external_id)
        if current is not None and current != row["user_id"]:
            return None, "这个微信号已经绑定了另一个瞬时账号，请先在原账号里解绑。"
        conn.execute("UPDATE channel_bind_codes SET used_at=? WHERE code=?", (stamp(now), code))
        self.bind(conn, channel, external_id, row["user_id"], display_name)
        return row["user_id"], None
